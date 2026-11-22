package main

import (
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

	putPath   string
	tracePath string
}

func newProxy(j *job, upstream *url.URL, transport http.RoundTripper, events chan<- event) *proxy {
	p := &proxy{
		job:       j,
		events:    events,
		putPath:   "/api/v4/jobs/" + strconv.FormatInt(j.id, 10),
		tracePath: "/api/v4/jobs/" + strconv.FormatInt(j.id, 10) + "/trace",
	}
	p.reverse = &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(upstream)
			// SetURL joins the query of both; the upstream has none.
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
		p.observe(r, rec)
	}
	logger.Printf("%s %s %d %dms", r.Method, redact(r.URL.Path), rec.status(), time.Since(start).Milliseconds())
}

// observe reads GitLab's word on the job from the answer to one of the
// runner's own calls for it. The verdict is the last final Job-Status answered
// to the runner's PUT of the job (a 202 "running" may come first). A 403 to
// that PUT or to a trace PATCH before any verdict means GitLab ended the job;
// one after a verdict is ignored.
func (p *proxy) observe(r *http.Request, rec *recorder) {
	isPut := r.Method == http.MethodPut && r.URL.Path == p.putPath
	isTrace := r.Method == http.MethodPatch && r.URL.Path == p.tracePath
	if !isPut && !isTrace {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if isPut {
		if _, final := verdictCodes[rec.jobStatus]; final {
			if p.verdict != rec.jobStatus {
				p.verdict = rec.jobStatus
				logger.Printf("GitLab's verdict on the job job=%d status=%s", p.job.id, p.verdict)
				p.events <- event{verdict: p.verdict}
			}
			return
		}
	}
	if rec.status() == http.StatusForbidden && p.verdict == "" && !p.ended {
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

// recorder notes the status and Job-Status sent to the runner and passes
// everything else, flushes included, straight through.
type recorder struct {
	http.ResponseWriter
	code      int
	jobStatus string
}

func (r *recorder) WriteHeader(code int) {
	if r.code == 0 {
		r.code = code
		r.jobStatus = r.Header().Get("Job-Status")
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
	for {
		select {
		case err := <-exited:
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
			if ev.ended {
				h.end(pid, exited)
				return exitEnded
			}
			if ev.idle {
				h.end(pid, exited)
				return exitFailed
			}
			if verdict == "" {
				// SIGQUIT: the runner finishes what it is doing for the job,
				// then exits.
				_ = syscall.Kill(pid, syscall.SIGQUIT)
				graceC = time.After(h.grace)
			}
			verdict = ev.verdict
		case <-graceC:
			logger.Printf("runner did not exit after the verdict; ending it")
			h.end(pid, exited)
			return verdictCodes[verdict]
		case <-deadline.C:
			logger.Printf("job passed its deadline; ending the runner job=%d", h.job.id)
			h.end(pid, exited)
			return exitFailed
		case sig := <-sigs:
			s := sig.(syscall.Signal)
			// To the runner alone: it ends its job its own way (SIGQUIT lets
			// it finish).
			// The runner's exit, or a verdict that comes meanwhile, still decides.
			logger.Printf("stop signal %s; passing it to the runner", s)
			stopping = s
			_ = syscall.Kill(pid, s)
		}
	}
}

// end stops the runner's process group, killing it if it lingers.
func (h *handover) end(pid int, exited <-chan error) {
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	select {
	case <-exited:
	case <-time.After(h.killWait):
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		<-exited
	}
	// Whatever the job started and left in the group goes too.
	_ = syscall.Kill(-pid, syscall.SIGKILL)
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
