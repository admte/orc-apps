package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/tls"
	"encoding/json"
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

// handover runs a stock runner for one job and ends it once the job is over.
// The job is either supplied (job set), served to the runner from loopback, or
// taken by the runner straight from GitLab with its own token (direct).
type handover struct {
	job      *job   // the supplied job; nil when direct
	direct   bool   // the runner takes one job from GitLab with token
	token    string // the runner token, when direct
	upstream *url.URL
	runner   string
	dir      string
	user     string
	home     string
	jobUID   int           // uid of user; 0 when unknown
	grace    time.Duration // how long the runner has to exit once GitLab gave a verdict
	killWait time.Duration // how long an ended runner has before it is killed
	now      func() time.Time
	onStop   func() // told of a stop signal before the runner is
}

// event is what the proxy learns of the job from GitLab's answers.
type event struct {
	taken   *job   // direct: GitLab answered the runner's job request with this job
	lost    bool   // direct: GitLab answered with a job whose answer could not be read
	refused bool   // direct: GitLab refused the runner token before a job
	verdict string // "success", "failed" or "canceled"
	ended   bool   // GitLab refused the job's token before any verdict
	idle    bool   // the runner asked for more work with no verdict on its job
}

var verdictCodes = map[string]int{"success": exitSuccess, "failed": exitFailed, "canceled": exitCanceled}

const (
	jobRequestPath = "/api/v4/jobs/request"
	verifyPath     = "/api/v4/runners/verify"
)

// The largest job GitLab's answer may carry, in direct mode, where the answer
// is read whole before it is passed on.
const maxJobBytes = 64 << 20

// proxy stands between the runner and GitLab. With a supplied job it answers
// the runner's job request and verify calls itself; direct, it passes the
// runner's job requests upstream, one at a time, until one answers with a job,
// and answers every later one itself. Every other call goes to GitLab
// unchanged, streaming both ways.
type proxy struct {
	direct  bool
	served  atomic.Bool // the runner has its job
	reverse *httputil.ReverseProxy
	events  chan<- event

	asking sync.Mutex // held while a job request is upstream

	mu       sync.Mutex
	job      *job   // nil until the runner has its job, when direct
	jobPath  string // /api/v4/jobs/{id}: the job's own endpoint and the root of its others
	verdict  string
	ended    bool
	idle     bool
	refused  bool
	stopping bool
	touched  bool // the runner called the job's own endpoints

	upstream  *url.URL
	transport http.RoundTripper
}

// inboundKey carries the runner's own request to ModifyResponse.
type inboundKey struct{}

// newProxy serves j to the runner, or, with j nil, lets the runner take one job
// from upstream itself.
func newProxy(j *job, upstream *url.URL, transport http.RoundTripper, events chan<- event) *proxy {
	p := &proxy{direct: j == nil, events: events, upstream: upstream, transport: transport}
	if j != nil {
		p.setJob(j)
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
			in, ok := resp.Request.Context().Value(inboundKey{}).(*http.Request)
			if !ok {
				return nil
			}
			switch {
			case p.direct && in.Method == http.MethodPost && in.URL.Path == jobRequestPath:
				return p.observeJobRequest(resp)
			case p.direct && in.Method == http.MethodPost && in.URL.Path == verifyPath:
				p.observeRunnerAnswer(resp.StatusCode)
			default:
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

// setJob makes j the job whose answers the proxy reads.
func (p *proxy) setJob(j *job) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.job = j
	if j != nil {
		p.jobPath = "/api/v4/jobs/" + strconv.FormatInt(j.id, 10)
	}
}

// stop answers every job request from now on itself: a stopping runner takes
// no job it has not already asked GitLab for.
func (p *proxy) stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.stopping = true
}

func (p *proxy) isStopping() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.stopping
}

// newTransport is a client transport to GitLab: no compression of its own (the
// runner's Accept-Encoding passes through), redirects never followed (that is
// the client's), and the system's trust anchors.
func newTransport() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.DisableCompression = true
	t.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	t.ResponseHeaderTimeout = 0
	return t
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	rec := &recorder{ResponseWriter: w}
	switch {
	case r.Method == http.MethodPost && r.URL.Path == jobRequestPath && p.direct:
		p.askUpstream(rec, r)
	case r.Method == http.MethodPost && r.URL.Path == jobRequestPath:
		drain(r)
		if p.served.CompareAndSwap(false, true) {
			p.mu.Lock()
			j := p.job
			p.mu.Unlock()
			rec.Header().Set("Content-Type", "application/json")
			rec.Header().Set("Content-Length", strconv.Itoa(len(j.raw)))
			rec.WriteHeader(http.StatusCreated)
			_, _ = rec.Write(j.raw)
			logger.Printf("job handed to the runner job=%d", j.id)
		} else {
			rec.WriteHeader(http.StatusNoContent)
			p.noteIdle()
		}
	case r.Method == http.MethodPost && r.URL.Path == verifyPath && !p.direct:
		drain(r)
		body := `{"id":0,"token":"` + placeholderToken + `","token_expires_at":null}`
		rec.Header().Set("Content-Type", "application/json")
		rec.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(rec, body)
	default:
		p.noteTouched(r.URL.Path)
		p.reverse.ServeHTTP(rec, r)
	}
	logger.Printf("%s %s %d %dms", r.Method, redact(r.URL.Path), rec.status(), time.Since(start).Milliseconds())
}

// askUpstream passes the runner's job request to GitLab unchanged (its body,
// X-Gitlab-Last-Update and GitLab's hold of it) while the runner has no job,
// one request at a time. Once it has one, or once it is stopping, the answer
// is "no job", given here.
func (p *proxy) askUpstream(w http.ResponseWriter, r *http.Request) {
	p.asking.Lock()
	defer p.asking.Unlock()
	if p.served.Load() || p.isStopping() {
		drain(r)
		w.WriteHeader(http.StatusNoContent)
		p.noteIdle()
		return
	}
	// GitLab's answer is read whatever becomes of the runner's request: a job
	// it hands out is taken, and is recorded as such, even if the runner has
	// gone by the time it comes.
	p.reverse.ServeHTTP(w, r.WithContext(context.WithoutCancel(r.Context())))
}

// observeJobRequest reads GitLab's answer to a job request passed upstream. A
// 201 is the job taken, whatever follows: no later job request goes upstream.
// The job is read whole, its bytes passed on unchanged, and the runner holds
// it from then on; one that cannot be read is lost. A refusal before any job
// means GitLab refused the token.
func (p *proxy) observeJobRequest(resp *http.Response) error {
	if resp.StatusCode != http.StatusCreated {
		p.observeRunnerAnswer(resp.StatusCode)
		return nil
	}
	p.mu.Lock()
	p.served.Store(true)
	p.mu.Unlock()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxJobBytes+1))
	_ = resp.Body.Close()
	if err == nil && len(body) > maxJobBytes {
		err = errors.New("larger than 64 MiB")
	}
	if err != nil {
		p.mu.Lock()
		defer p.mu.Unlock()
		logger.Printf("GitLab gave the runner a job whose answer could not be read; the job is lost: %s", redact(err.Error()))
		p.events <- event{lost: true}
		return fmt.Errorf("reading the job GitLab gave: %w", err)
	}
	resp.Body = io.NopCloser(bytes.NewReader(body))
	resp.ContentLength = int64(len(body))
	resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
	resp.Header.Del("Transfer-Encoding")
	resp.TransferEncoding = nil

	plain := body
	if strings.EqualFold(resp.Header.Get("Content-Encoding"), "gzip") {
		zr, err := gzip.NewReader(bytes.NewReader(body))
		if err == nil {
			plain, err = io.ReadAll(io.LimitReader(zr, maxJobBytes))
		}
		if err != nil {
			plain = nil
		}
	}
	j, err := parseJob(bytes.TrimSpace(plain))
	if err != nil {
		// The runner runs it all the same; with no id the proxy cannot tell
		// its answers apart, and the runner's next job request ends it.
		logger.Printf("GitLab gave the runner a job this helper cannot read: %v", err)
		j = &job{id: -1, timeout: time.Hour}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if j.id >= 0 {
		p.job = j
		p.jobPath = "/api/v4/jobs/" + strconv.FormatInt(j.id, 10)
	}
	logger.Printf("GitLab gave the runner its job job=%d", j.id)
	p.events <- event{taken: j}
	return nil
}

// noteTouched records a runner call on the job's own endpoints.
func (p *proxy) noteTouched(path string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.jobPath != "" && (path == p.jobPath || strings.HasPrefix(path, p.jobPath+"/")) {
		p.touched = true
	}
}

// failUntouched tells GitLab at once that a job taken from it failed, when
// the runner never called any of the job's endpoints and GitLab gave no
// verdict: its answer was lost between this proxy and the runner, and GitLab
// would otherwise hold the job running until it drops it.
func (p *proxy) failUntouched() {
	p.mu.Lock()
	j, skip := p.job, p.touched || p.verdict != "" || p.ended
	p.mu.Unlock()
	if j == nil || skip || j.token == "" {
		return
	}
	body, _ := json.Marshal(map[string]string{
		"token": j.token, "state": "failed", "failure_reason": "runner_system_failure",
	})
	u := *p.upstream
	u.Path = strings.TrimRight(u.Path, "/") + "/api/v4/jobs/" + strconv.FormatInt(j.id, 10)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, u.String(), bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("JOB-TOKEN", j.token)
	resp, err := (&http.Client{Transport: p.transport}).Do(req)
	if err != nil {
		logger.Printf("could not tell GitLab the job the runner never ran failed job=%d error=%s", j.id, redact(err.Error()))
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	_ = resp.Body.Close()
	logger.Printf("told GitLab the job the runner never ran failed job=%d status=%d", j.id, resp.StatusCode)
}

// observeRunnerAnswer reads GitLab's answer to a call made with the runner
// token: 401 or 403 before any job means GitLab refuses the token.
func (p *proxy) observeRunnerAnswer(status int) {
	if status != http.StatusUnauthorized && status != http.StatusForbidden {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.served.Load() || p.refused {
		return
	}
	p.refused = true
	logger.Printf("GitLab refused the runner token status=%d", status)
	p.events <- event{refused: true}
}

// observe reads GitLab's word on the job from its answer to one of the
// runner's calls. The verdict is the final Job-Status of the last 2xx answer to
// the runner's PUT of the job (a 202 "running" may come first). A 403 on any of
// the job's own endpoints before a verdict means GitLab ended the job, whatever
// Job-Status it carries; one after a verdict is ignored.
func (p *proxy) observe(method, path string, status int, jobStatus string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.jobPath == "" || (path != p.jobPath && !strings.HasPrefix(path, p.jobPath+"/")) {
		return
	}
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
		logger.Printf("runner asked for more work with no verdict on its job")
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

// run serves or lets the runner take its job and supervises the runner; it
// returns the exit code.
func (h *handover) run() (int, error) {
	if h.now == nil {
		h.now = time.Now
	}
	events := make(chan event, 16)
	p := newProxy(h.job, h.upstream, newTransport(), events)
	h.onStop = p.stop
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return exitFailed, err
	}
	srv := &http.Server{Handler: p, ReadHeaderTimeout: 30 * time.Second}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	config := filepath.Join(h.dir, "config.toml")
	defer os.Remove(config)
	rc := runnerConfig{
		name: "handover", url: "http://" + ln.Addr().String(), token: placeholderToken,
		home: h.home, concurrent: 1, limit: 1,
	}
	if h.direct {
		rc.token = h.token
		if rc.name, _ = os.Hostname(); rc.name == "" {
			rc.name = "gitlab-runner"
		}
	}
	if err := writeConfig(config, rc); err != nil {
		return exitFailed, err
	}

	// `run`, not `run-single`: only `run` drops jobs to another account
	// (--user). The runner stays root, so its root-only config stays root-only.
	// It takes one job (the proxy gives it no other) and is asked to stop once
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
	if h.direct {
		logger.Printf("runner started; it takes one job url=%s", redact(h.upstream.String()))
	} else {
		logger.Printf("runner started job=%d", h.job.id)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	code := h.supervise(cmd.Process.Pid, exited, events, sigs)
	if h.direct {
		p.failUntouched()
	}
	return code, nil
}

// How a run ended, before it is turned into an exit code.
type endKind int

const (
	endVerdict    endKind = iota // GitLab gave a verdict
	endEnded                     // GitLab refused the job's token before a verdict
	endIdle                      // the runner asked for more work with no verdict
	endDeadline                  // the job passed its deadline with no verdict
	endStopped                   // a stop signal, before any verdict
	endRunnerExit                // the runner exited on its own before any verdict
	endRefused                   // direct: GitLab refused the runner token
	endLost                      // direct: GitLab gave a job whose answer could not be read
)

type ending struct {
	kind    endKind
	verdict string
	signal  syscall.Signal // endStopped
	taken   bool           // the runner had its job
	jobID   int64
}

// exitCode turns how a run ended into the helper's exit status. A supplied
// job exits with its outcome. Direct, the outcome is printed and the exit is
// 0 whenever the runner could work, 1 when GitLab refused the token or the
// runner ended before it took a job without being asked to.
func (h *handover) exitCode(e ending) int {
	if !h.direct {
		switch e.kind {
		case endVerdict:
			return verdictCodes[e.verdict]
		case endEnded:
			return exitEnded
		case endStopped:
			return 128 + int(e.signal)
		}
		return exitFailed
	}
	outcome := ""
	switch e.kind {
	case endVerdict:
		outcome = e.verdict
	case endEnded:
		outcome = "ended by GitLab"
	case endIdle, endRunnerExit:
		outcome = "no verdict"
	case endDeadline:
		outcome = "passed its deadline"
	case endStopped:
		outcome = "stopped before a verdict"
	}
	if e.kind == endLost {
		fmt.Println("gitlab-runner: job lost; GitLab's answer could not be read")
		return 0
	}
	switch {
	case e.kind == endRefused:
		fmt.Println("gitlab-runner: GitLab refused the runner token; no job taken")
		return 1
	case !e.taken && e.kind == endStopped:
		fmt.Println("gitlab-runner: stopped before taking a job")
		return 0
	case !e.taken:
		fmt.Println("gitlab-runner: the runner ended before taking a job")
		return 1
	}
	fmt.Printf("gitlab-runner: job %d: %s\n", e.jobID, outcome)
	return 0
}

// supervise waits for the end of the job and returns the exit code. The runner
// exits 0 whatever happened to the job, and after a job ended on GitLab's side
// it asks for another, so it is ended here in every case but its own exit.
func (h *handover) supervise(pid int, exited <-chan error, events <-chan event, sigs <-chan os.Signal) int {
	if h.now == nil {
		h.now = time.Now
	}
	var deadline *time.Timer
	var deadlineC <-chan time.Time
	arm := func(j *job) {
		if deadline != nil {
			deadline.Stop()
		}
		deadline = time.NewTimer(j.deadline(h.now()).Sub(h.now()))
		deadlineC = deadline.C
	}
	defer func() {
		if deadline != nil {
			deadline.Stop()
		}
	}()
	taken := false
	var jobID int64
	if h.job != nil {
		taken, jobID = true, h.job.id
		arm(h.job)
	}
	var graceC <-chan time.Time
	verdict := ""
	var stopping syscall.Signal
	end := func(kind endKind) int {
		return h.exitCode(ending{kind: kind, verdict: verdict, signal: stopping, taken: taken, jobID: jobID})
	}
	// apply takes one event; it returns the exit code once the job is decided.
	apply := func(ev event) (int, bool) {
		switch {
		case ev.refused:
			return end(endRefused), true
		case ev.lost:
			taken = true
			return end(endLost), true
		case ev.taken != nil:
			taken, jobID = true, ev.taken.id
			arm(ev.taken)
			return 0, false
		case ev.ended:
			return end(endEnded), true
		case ev.idle:
			return end(endIdle), true
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
				return end(endVerdict)
			case stopping != 0 && !taken:
				logger.Printf("runner stopped before taking a job")
				return end(endStopped)
			case stopping != 0:
				logger.Printf("runner stopped before GitLab gave a verdict on the job")
				return end(endStopped)
			case !taken:
				logger.Printf("runner exited before taking a job status=%s", exitText(err))
				return end(endRunnerExit)
			}
			logger.Printf("runner exited before GitLab gave a verdict on the job status=%s", exitText(err))
			return end(endRunnerExit)
		case ev := <-events:
			if code, done := apply(ev); done {
				h.end(pid, exited)
				return code
			}
		case <-graceC:
			logger.Printf("runner did not exit after the verdict; ending it")
			h.end(pid, exited)
			return end(endVerdict)
		case <-deadlineC:
			h.end(pid, exited)
			if verdict != "" {
				return end(endVerdict)
			}
			logger.Printf("job passed its deadline; ended the runner job=%d", jobID)
			return end(endDeadline)
		case sig := <-sigs:
			// To the runner alone: it ends its job its own way (SIGQUIT lets
			// it finish). Its exit, or a verdict that comes meanwhile, decides.
			// The proxy first stops asking GitLab for a job: one a request
			// already upstream brings is still run.
			s := sig.(syscall.Signal)
			logger.Printf("stop signal %s; passing it to the runner", s)
			stopping = s
			if h.onStop != nil {
				h.onStop()
			}
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
