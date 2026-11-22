package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// handover serves one job to a stock runner and ends the runner once the job
// is over.
type handover struct {
	job      *job
	upstream *url.URL
	caFile   string
	runner   string
	dir      string
	user     string
	home     string
	jobUID   int           // uid of user; 0 when unknown
	grace    time.Duration // how long the runner has to exit once GitLab gave a verdict
	killWait time.Duration // how long an ended runner has before it is killed
	now      func() time.Time
}

// event is what the proxy learns of the job from GitLab's answers.
type event struct {
	verdict string // "success", "failed" or "canceled"
	ended   bool   // GitLab refused the job's token before any verdict
	idle    bool   // the runner asked for more work with no verdict on its job
}

var verdictCodes = map[string]int{"success": exitSuccess, "failed": exitFailed, "canceled": exitCanceled}

// proxy answers the runner's job request and verify calls itself and passes
// every other call to GitLab unchanged, streaming both ways.
type proxy struct {
	job     *job
	served  atomic.Bool
	reverse *httputil.ReverseProxy
	events  chan<- event

	mu      sync.Mutex
	verdict string
	ended   bool
	idle    bool

	jobPath string // /api/v4/jobs/{id}: the job's own endpoint and the root of its others
}

// inboundKey carries the runner's own request to ModifyResponse.
type inboundKey struct{}

func newProxy(j *job, upstream *url.URL, transport http.RoundTripper, events chan<- event) *proxy {
	p := &proxy{
		job:     j,
		events:  events,
		jobPath: "/api/v4/jobs/" + strconv.FormatInt(j.id, 10),
	}
	p.reverse = &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(upstream)
			// SetURL joins the query of both; the upstream has none.
			r.Out = r.Out.WithContext(context.WithValue(r.Out.Context(), inboundKey{}, r.In))
		},
		// Read before the answer is passed on, so the supervisor has GitLab's
		// word on the job before the runner can act on it.
		ModifyResponse: func(resp *http.Response) error {
			if in, ok := resp.Request.Context().Value(inboundKey{}).(*http.Request); ok {
				p.observe(in.Method, in.URL.Path, resp.StatusCode, resp.Header.Get("Job-Status"))
			}
			return nil
		},
		Transport:     transport,
		FlushInterval: -1,
		ErrorLog:      logger,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			var ue *url.Error
			if errors.As(err, &ue) {
				err = ue.Err
			}
			logger.Printf("upstream error method=%s path=%s error=%s", r.Method, redact(r.URL.Path), redact(err.Error()))
			w.WriteHeader(http.StatusBadGateway)
		},
	}
	return p
}

// newTransport is a client transport to GitLab: no compression of its own (the
// runner's Accept-Encoding passes through), redirects never followed (that is
// the client's), and the system's trust anchors plus caFile.
func newTransport(caFile string) (*http.Transport, error) {
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("cannot read --ca: %w", err)
		}
		if !pool.AppendCertsFromPEM(pem) {
			return nil, errors.New("--ca holds no PEM certificate")
		}
	}
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.DisableCompression = true
	t.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	t.ResponseHeaderTimeout = 0
	return t, nil
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	rec := &recorder{ResponseWriter: w}
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/api/v4/jobs/request":
		drain(r)
		if p.served.CompareAndSwap(false, true) {
			rec.Header().Set("Content-Type", "application/json")
			rec.Header().Set("Content-Length", strconv.Itoa(len(p.job.raw)))
			rec.WriteHeader(http.StatusCreated)
			_, _ = rec.Write(p.job.raw)
			logger.Printf("job handed to the runner job=%d", p.job.id)
		} else {
			rec.WriteHeader(http.StatusNoContent)
			p.noteIdle()
		}
	case r.Method == http.MethodPost && r.URL.Path == "/api/v4/runners/verify":
		drain(r)
		body := `{"id":0,"token":"` + placeholderToken + `","token_expires_at":null}`
		rec.Header().Set("Content-Type", "application/json")
		rec.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(rec, body)
	default:
		p.reverse.ServeHTTP(rec, r)
	}
	logger.Printf("%s %s %d %dms", r.Method, redact(r.URL.Path), rec.status(), time.Since(start).Milliseconds())
}

// observe reads GitLab's word on the job from its answer to one of the
// runner's calls. The verdict is the final Job-Status of the last 2xx answer to
// the runner's PUT of the job (a 202 "running" may come first). A 403 on any of
// the job's own endpoints before a verdict means GitLab ended the job, whatever
// Job-Status it carries; one after a verdict is ignored.
func (p *proxy) observe(method, path string, status int, jobStatus string) {
	ownJob := path == p.jobPath || strings.HasPrefix(path, p.jobPath+"/")
	if !ownJob {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if method == http.MethodPut && path == p.jobPath && status >= 200 && status < 300 {
		if _, final := verdictCodes[jobStatus]; final && p.verdict != jobStatus {
			p.verdict = jobStatus
			logger.Printf("GitLab's verdict on the job job=%d status=%s", p.job.id, p.verdict)
			p.events <- event{verdict: p.verdict}
		}
		return
	}
	if status == http.StatusForbidden && p.verdict == "" && !p.ended {
		p.ended = true
		logger.Printf("GitLab refused the job's token before a verdict; the job ended on GitLab's side job=%d", p.job.id)
		p.events <- event{ended: true}
	}
}

// noteIdle reports a job request after the job was served and before any
// verdict: the runner takes one job at a time, so it is done with this one
// without GitLab having said how it ended.
func (p *proxy) noteIdle() {
	if !p.served.Load() {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.verdict == "" && !p.ended && !p.idle {
		p.idle = true
		logger.Printf("runner asked for more work with no verdict on its job job=%d", p.job.id)
		p.events <- event{idle: true}
	}
}

func drain(r *http.Request) {
	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 1<<20))
	_ = r.Body.Close()
}

// recorder notes the status sent to the runner and passes
// everything else, flushes included, straight through.
type recorder struct {
	http.ResponseWriter
	code int
}

func (r *recorder) WriteHeader(code int) {
	if r.code == 0 {
		r.code = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	if r.code == 0 {
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(b)
}

func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func (r *recorder) status() int {
	if r.code == 0 {
		return http.StatusOK
	}
	return r.code
}

// run serves the job and supervises the runner; it returns the exit code.
func (h *handover) run() (int, error) {
	if h.now == nil {
		h.now = time.Now
	}
	transport, err := newTransport(h.caFile)
	if err != nil {
		return exitFailed, err
	}
	events := make(chan event, 16)
	p := newProxy(h.job, h.upstream, transport, events)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return exitFailed, err
	}
	srv := &http.Server{Handler: p, ReadHeaderTimeout: 30 * time.Second}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	config := filepath.Join(h.dir, "config.toml")
	defer os.Remove(config)
	if err := writeConfig(config, runnerConfig{
		name: "handover", url: "http://" + ln.Addr().String(), token: placeholderToken,
		home: h.home, concurrent: 1, limit: 1,
	}); err != nil {
		return exitFailed, err
	}

	// `run`, not `run-single`: only `run` drops jobs to another account
	// (--user). The runner stays root, so its root-only config stays root-only.
	// It takes this one job (the proxy has no other) and is asked to stop once
	// GitLab gives its verdict.
	cmd := exec.Command(h.runner, "run", "--config", config, "--user", h.user,
		"--working-directory", h.home)
	cmd.Dir = h.home
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT)
	defer signal.Stop(sigs)
	if err := cmd.Start(); err != nil {
		return exitFailed, fmt.Errorf("cannot start the runner: %w", err)
	}
	logger.Printf("runner started job=%d", h.job.id)
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	return h.supervise(cmd.Process.Pid, exited, events, sigs), nil
}

// supervise waits for the end of the job and returns the exit code. The runner
// exits 0 whatever happened to the job, and after a job ended on GitLab's side
// it asks for another, so it is ended here in every case but its own exit.
func (h *handover) supervise(pid int, exited <-chan error, events <-chan event, sigs <-chan os.Signal) int {
	deadline := time.NewTimer(h.job.deadline(h.now()).Sub(h.now()))
	defer deadline.Stop()
	var graceC <-chan time.Time
	verdict := ""
	var stopping syscall.Signal
	// apply takes one event; it returns the exit code once the job is decided.
	apply := func(ev event) (int, bool) {
		switch {
		case ev.ended:
			return exitEnded, true
		case ev.idle:
			return exitFailed, true
		}
		if verdict == "" {
			// SIGQUIT: the runner finishes what it is doing for the job,
			// then exits.
			_ = syscall.Kill(pid, syscall.SIGQUIT)
			graceC = time.After(h.grace)
		}
		verdict = ev.verdict
		return 0, false
	}
	for {
		select {
		case err := <-exited:
			// What GitLab said before the runner exited decides, though the
			// exit may be seen first.
			for drained := false; !drained; {
				select {
				case ev := <-events:
					if code, done := apply(ev); done {
						h.endJob()
						return code
					}
				default:
					drained = true
				}
			}
			h.endJob()
			switch {
			case verdict != "":
				logger.Printf("runner exited; job outcome %s", verdict)
				return verdictCodes[verdict]
			case stopping != 0:
				logger.Printf("runner stopped before GitLab gave a verdict on the job")
				return 128 + int(stopping)
			}
			logger.Printf("runner exited before GitLab gave a verdict on the job status=%s", exitText(err))
			return exitFailed
		case ev := <-events:
			if code, done := apply(ev); done {
				h.end(pid, exited)
				return code
			}
		case <-graceC:
			logger.Printf("runner did not exit after the verdict; ending it")
			h.end(pid, exited)
			return verdictCodes[verdict]
		case <-deadline.C:
			h.end(pid, exited)
			if verdict != "" {
				return verdictCodes[verdict]
			}
			logger.Printf("job passed its deadline; ended the runner job=%d", h.job.id)
			return exitFailed
		case sig := <-sigs:
			// To the runner alone: it ends its job its own way (SIGQUIT lets
			// it finish). Its exit, or a verdict that comes meanwhile, decides.
			s := sig.(syscall.Signal)
			logger.Printf("stop signal %s; passing it to the runner", s)
			stopping = s
			_ = syscall.Kill(pid, s)
		}
	}
}

// end stops the runner's process group, killing it if it lingers, then
// whatever the job left behind.
func (h *handover) end(pid int, exited <-chan error) {
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	select {
	case <-exited:
	case <-time.After(h.killWait):
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		<-exited
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	h.endJob()
}

// endJob kills every process of the account jobs run as. A job runs through su,
// which puts it in a session of its own: neither the runner's process group nor
// the service's cgroup holds it, so a job's leftovers would outlive the runner.
func (h *handover) endJob() {
	if h.jobUID > 0 {
		killUser(h.jobUID)
	}
}

// killUser sends SIGKILL to every process whose real or effective uid is uid,
// a few passes over, for processes forked meanwhile. Never root's.
func killUser(uid int) {
	if uid <= 0 {
		return
	}
	want := strconv.Itoa(uid)
	for pass := 0; pass < 3; pass++ {
		entries, err := os.ReadDir("/proc")
		if err != nil {
			return
		}
		found := false
		for _, e := range entries {
			pid, err := strconv.Atoi(e.Name())
			if err != nil {
				continue
			}
			status, err := os.ReadFile("/proc/" + e.Name() + "/status")
			if err != nil {
				continue
			}
			for _, line := range strings.Split(string(status), "\n") {
				if f := strings.Fields(line); len(f) >= 3 && f[0] == "Uid:" && (f[1] == want || f[2] == want) {
					_ = syscall.Kill(pid, syscall.SIGKILL)
					found = true
				}
			}
		}
		if !found {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func exitText(err error) string {
	if err == nil {
		return "0"
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ProcessState.String()
	}
	return err.Error()
}
