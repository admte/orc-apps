package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

const runnerToken = "glrt-SECRETrunnertoken"

// TestMain lets the test binary stand in for gitlab-runner (see fakeRunner).
func TestMain(m *testing.M) {
	if os.Getenv("HANDOVER_FAKE_RUNNER") == "1" {
		os.Exit(fakeRunner(os.Args[1:]))
	}
	os.Exit(m.Run())
}

// directGitLab answers what a runner asks with its own token: verify, and job
// requests from a script (204 until the scripted 201), and the job's PUT.
type directGitLab struct {
	mu          sync.Mutex
	requests    int // job requests that reached it
	bodies      []string
	lastUpdate  []string
	inFlight    int
	maxInFlight int
	noJobs      int    // job requests answered 204 before the job
	refuse      bool   // answer the runner token with 403
	verdict     string // Job-Status of the job's PUT
	hold        time.Duration
	gzip        bool
	payload     []byte
	srv         *httptest.Server
}

func newDirectGitLab(t *testing.T, payload []byte) *directGitLab {
	g := &directGitLab{payload: payload, verdict: "failed"}
	g.srv = httptest.NewServer(http.HandlerFunc(g.serve))
	t.Cleanup(g.srv.Close)
	return g
}

func (g *directGitLab) serve(w http.ResponseWriter, r *http.Request) {
	g.mu.Lock()
	refuse, verdict := g.refuse, g.verdict
	g.mu.Unlock()
	switch {
	case r.Method == http.MethodPost && r.URL.Path == verifyPath:
		body, _ := io.ReadAll(r.Body)
		if refuse || !strings.Contains(string(body), runnerToken) {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		_, _ = io.WriteString(w, `{"id":9,"token":"`+runnerToken+`"}`)
	case r.Method == http.MethodPost && r.URL.Path == jobRequestPath:
		body, _ := io.ReadAll(r.Body)
		g.mu.Lock()
		g.requests++
		g.bodies = append(g.bodies, string(body))
		g.lastUpdate = append(g.lastUpdate, r.Header.Get("X-Gitlab-Last-Update"))
		g.inFlight++
		g.maxInFlight = max(g.maxInFlight, g.inFlight)
		answerNoJob := g.noJobs > 0
		if answerNoJob {
			g.noJobs--
		}
		hold := g.hold
		g.mu.Unlock()
		time.Sleep(hold)
		g.mu.Lock()
		g.inFlight--
		g.mu.Unlock()
		switch {
		case refuse || !strings.Contains(string(body), runnerToken):
			w.WriteHeader(http.StatusForbidden)
		case answerNoJob:
			w.Header().Set("X-Gitlab-Last-Update", "upd-1")
			w.WriteHeader(http.StatusNoContent)
		case g.gzip && strings.Contains(r.Header.Get("Accept-Encoding"), "gzip"):
			var b bytes.Buffer
			zw := gzip.NewWriter(&b)
			_, _ = zw.Write(g.payload)
			_ = zw.Close()
			w.Header().Set("Content-Encoding", "gzip")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write(b.Bytes())
		default:
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write(g.payload)
		}
	case r.Method == http.MethodPut && r.URL.Path == "/api/v4/jobs/42":
		if r.Header.Get("JOB-TOKEN") != jobToken {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.Header().Set("Job-Status", verdict)
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (g *directGitLab) jobRequests() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.requests
}

func askForJob(t *testing.T, base, lastUpdate string) (*http.Response, []byte) {
	t.Helper()
	hdr := map[string]string{"Content-Type": "application/json"}
	if lastUpdate != "" {
		hdr["X-Gitlab-Last-Update"] = lastUpdate
	}
	resp := do(t, http.MethodPost, base+jobRequestPath, strings.NewReader(`{"token":"`+runnerToken+`","last_update":"`+lastUpdate+`"}`), hdr)
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return resp, body
}

func TestDirectJobRequestsGoUpstreamUntilAJob(t *testing.T) {
	captureLog(t)
	payload := testPayload(t, 42, 600, "")
	g := newDirectGitLab(t, payload)
	g.noJobs = 2
	srv, events := startProxy(t, nil, g.srv.URL)

	// GitLab's "no job" answers pass through, headers included.
	for _, upd := range []string{"", "upd-1"} {
		resp, _ := askForJob(t, srv.URL, upd)
		if resp.StatusCode != http.StatusNoContent || resp.Header.Get("X-Gitlab-Last-Update") != "upd-1" {
			t.Fatalf("no-job answer changed: %d %v", resp.StatusCode, resp.Header)
		}
	}
	resp, body := askForJob(t, srv.URL, "upd-1")
	if resp.StatusCode != http.StatusCreated || !bytes.Equal(body, payload) {
		t.Fatalf("job answer changed: %d", resp.StatusCode)
	}
	if ev, ok := nextEvent(t, events); !ok || ev.taken == nil || ev.taken.id != 42 {
		t.Fatalf("no taken event: %+v", ev)
	}
	g.mu.Lock()
	if g.requests != 3 || g.lastUpdate[2] != "upd-1" || !strings.Contains(g.bodies[0], runnerToken) {
		t.Fatalf("requests reached GitLab changed: %d %v", g.requests, g.lastUpdate)
	}
	g.mu.Unlock()

	// Every later request is answered here, and with no verdict yet it means
	// the runner is done with its job.
	resp, _ = askForJob(t, srv.URL, "")
	if resp.StatusCode != http.StatusNoContent || g.jobRequests() != 3 {
		t.Fatalf("later request: %d, upstream saw %d", resp.StatusCode, g.jobRequests())
	}
	if ev, ok := nextEvent(t, events); !ok || !ev.idle {
		t.Fatalf("no idle event: %+v", ev)
	}
}

func TestDirectVerdictOfTheTakenJob(t *testing.T) {
	captureLog(t)
	g := newDirectGitLab(t, testPayload(t, 42, 600, ""))
	srv, events := startProxy(t, nil, g.srv.URL)
	askForJob(t, srv.URL, "")
	if ev, _ := nextEvent(t, events); ev.taken == nil {
		t.Fatalf("no taken event: %+v", ev)
	}
	put(t, srv.URL)
	if ev, ok := nextEvent(t, events); !ok || ev.verdict != "failed" {
		t.Fatalf("no verdict: %+v", ev)
	}
}

func TestDirectOneJobRequestAtATime(t *testing.T) {
	captureLog(t)
	payload := testPayload(t, 42, 600, "")
	g := newDirectGitLab(t, payload)
	g.hold = 20 * time.Millisecond
	srv, _ := startProxy(t, nil, g.srv.URL)
	var created atomic.Int32
	var wg sync.WaitGroup
	for range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, _ := askForJob(t, srv.URL, "")
			if resp.StatusCode == http.StatusCreated {
				created.Add(1)
			}
		}()
	}
	wg.Wait()
	g.mu.Lock()
	defer g.mu.Unlock()
	if created.Load() != 1 || g.requests != 1 || g.maxInFlight != 1 {
		t.Fatalf("created %d, upstream requests %d, at once %d", created.Load(), g.requests, g.maxInFlight)
	}
}

func TestDirectGzippedJobPassedUnchanged(t *testing.T) {
	captureLog(t)
	payload := testPayload(t, 42, 600, "")
	g := newDirectGitLab(t, payload)
	g.gzip = true
	srv, events := startProxy(t, nil, g.srv.URL)
	// A client that leaves the encoding to its caller, as the bytes go.
	client := &http.Client{Transport: &http.Transport{DisableCompression: true}}
	req, _ := http.NewRequest(http.MethodPost, srv.URL+jobRequestPath, strings.NewReader(`{"token":"`+runnerToken+`"}`))
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	zr, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil || resp.Header.Get("Content-Encoding") != "gzip" {
		t.Fatalf("not gzip: %v %v", err, resp.Header)
	}
	plain, _ := io.ReadAll(zr)
	if !bytes.Equal(plain, payload) {
		t.Fatal("gzipped job changed on the way")
	}
	if ev, ok := nextEvent(t, events); !ok || ev.taken == nil || ev.taken.id != 42 {
		t.Fatalf("gzipped job not read: %+v", ev)
	}
}

func TestDirectVerifyGoesUpstreamAndARefusalIsReported(t *testing.T) {
	for _, path := range []string{verifyPath, jobRequestPath} {
		t.Run(path, func(t *testing.T) {
			captureLog(t)
			g := newDirectGitLab(t, testPayload(t, 42, 600, ""))
			srv, events := startProxy(t, nil, g.srv.URL)
			if path == verifyPath {
				resp := do(t, http.MethodPost, srv.URL+verifyPath, strings.NewReader(`{"token":"`+runnerToken+`"}`), nil)
				body, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				if resp.StatusCode != 200 || !strings.Contains(string(body), `"id":9`) {
					t.Fatalf("verify not GitLab's: %d %s", resp.StatusCode, body)
				}
				if ev, ok := nextEvent(t, events); ok {
					t.Fatalf("accepted verify gave %+v", ev)
				}
			}
			g.mu.Lock()
			g.refuse = true
			g.mu.Unlock()
			resp := do(t, http.MethodPost, srv.URL+path, strings.NewReader(`{"token":"`+runnerToken+`"}`), nil)
			resp.Body.Close()
			if resp.StatusCode != http.StatusForbidden {
				t.Fatalf("refusal not passed on: %d", resp.StatusCode)
			}
			if ev, ok := nextEvent(t, events); !ok || !ev.refused {
				t.Fatalf("no refused event: %+v", ev)
			}
		})
	}
}

func TestDirectStoppingAsksGitLabForNoJob(t *testing.T) {
	captureLog(t)
	g := newDirectGitLab(t, testPayload(t, 42, 600, ""))
	g.noJobs = 1
	u, _ := url.Parse(g.srv.URL)
	events := make(chan event, 16)
	p := newProxy(nil, u, newTransport(), events)
	srv := httptest.NewServer(p)
	defer srv.Close()
	askForJob(t, srv.URL, "")
	p.stop()
	resp, _ := askForJob(t, srv.URL, "")
	if resp.StatusCode != http.StatusNoContent || g.jobRequests() != 1 {
		t.Fatalf("stopping: %d, upstream saw %d", resp.StatusCode, g.jobRequests())
	}
	if ev, ok := nextEvent(t, events); ok {
		t.Fatalf("a stop before a job gave %+v", ev)
	}
}

func TestDirectStopLetsAJobAlreadyAskedForRun(t *testing.T) {
	captureLog(t)
	g := newDirectGitLab(t, testPayload(t, 42, 600, ""))
	g.hold = 200 * time.Millisecond
	u, _ := url.Parse(g.srv.URL)
	events := make(chan event, 16)
	p := newProxy(nil, u, newTransport(), events)
	srv := httptest.NewServer(p)
	defer srv.Close()
	got := make(chan int, 1)
	go func() {
		resp, _ := askForJob(t, srv.URL, "")
		got <- resp.StatusCode
	}()
	for g.jobRequests() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	p.stop()
	if code := <-got; code != http.StatusCreated {
		t.Fatalf("the job already asked for was not passed on: %d", code)
	}
	if ev, ok := nextEvent(t, events); !ok || ev.taken == nil {
		t.Fatalf("no taken event: %+v", ev)
	}
}

// takenJob is a job whose deadline is in d.
func takenJob(t *testing.T, d time.Duration) *job {
	t.Helper()
	started := time.Now().Add(-(60*time.Second + 15*time.Minute) + d).UTC()
	j, err := parseJob(testPayload(t, 42, 60, started.Format(time.RFC3339Nano)))
	if err != nil {
		t.Fatal(err)
	}
	return j
}

func TestDirectExitCodes(t *testing.T) {
	captureLog(t)
	taken := func() event { return event{taken: takenJob(t, time.Hour)} }
	cases := []struct {
		name   string
		events []event
		signal bool
		want   int
	}{
		{"success", []event{taken(), {verdict: "success"}}, false, 0},
		{"failed", []event{taken(), {verdict: "failed"}}, false, 0},
		{"canceled", []event{taken(), {verdict: "canceled"}}, false, 0},
		{"ended by GitLab", []event{taken(), {ended: true}}, false, 0},
		{"no verdict", []event{taken(), {idle: true}}, false, 0},
		{"deadline", []event{{taken: takenJob(t, 200*time.Millisecond)}}, false, 0},
		{"stopped during a job", []event{taken()}, true, 0},
		{"stopped before a job", nil, true, 0},
		{"token refused", []event{{refused: true}}, false, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pid, exited := sleeper(t)
			events := make(chan event, 4)
			for _, ev := range c.events {
				events <- ev
			}
			sigs := make(chan os.Signal, 1)
			if c.signal {
				// sleep ends on the passed SIGTERM, as the runner does.
				time.AfterFunc(50*time.Millisecond, func() { sigs <- syscall.SIGTERM })
			}
			stopped := false
			h := &handover{direct: true, grace: 300 * time.Millisecond, killWait: 2 * time.Second,
				onStop: func() { stopped = true }}
			if code := h.supervise(pid, exited, events, sigs); code != c.want {
				t.Fatalf("exit %d, want %d", code, c.want)
			}
			if c.signal && !stopped {
				t.Fatal("the proxy was not told of the stop")
			}
			if alive(pid) {
				t.Fatal("runner still running")
			}
		})
	}
}

func TestDirectRunnerEndingBeforeAJobIsAFailure(t *testing.T) {
	captureLog(t)
	exited := make(chan error, 1)
	exited <- nil
	h := &handover{direct: true, grace: time.Second, killWait: time.Second}
	if code := h.supervise(1<<22+1, exited, make(chan event), make(chan os.Signal)); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	// Once it had its job, its own exit is the end of the job.
	exited <- nil
	events := make(chan event, 1)
	events <- event{taken: takenJob(t, time.Hour)}
	if code := h.supervise(1<<22+1, exited, events, make(chan os.Signal)); code != 0 {
		t.Fatalf("exit %d, want 0", code)
	}
}

// fakeRunner stands in for `gitlab-runner run --config PATH …`: it reads its
// url and token from the config, verifies, asks for jobs until it gets one,
// reports it failed, and keeps asking until it is stopped.
func fakeRunner(args []string) int {
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGQUIT, syscall.SIGTERM)
	config := ""
	for i, a := range args {
		if a == "--config" && i+1 < len(args) {
			config = args[i+1]
		}
	}
	b, err := os.ReadFile(config)
	if err != nil {
		return 70
	}
	field := func(name string) string {
		m := regexp.MustCompile(`(?m)^\s*` + name + ` = "([^"]*)"`).FindSubmatch(b)
		if m == nil {
			return ""
		}
		return string(m[1])
	}
	base, token := field("url"), field("token")
	post := func(path, body string, hdr map[string]string) (*http.Response, []byte) {
		req, _ := http.NewRequest(http.MethodPost, base+path, strings.NewReader(body))
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return &http.Response{StatusCode: 599}, nil
		}
		out, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp, out
	}
	post(verifyPath, `{"token":"`+token+`"}`, nil)
	for {
		select {
		case <-sigs:
			return 0
		default:
		}
		resp, body := post(jobRequestPath, `{"token":"`+token+`"}`, nil)
		if resp.StatusCode == http.StatusCreated {
			var j struct {
				ID    int64  `json:"id"`
				Token string `json:"token"`
			}
			_ = json.Unmarshal(body, &j)
			req, _ := http.NewRequest(http.MethodPut, base+"/api/v4/jobs/"+strconv.FormatInt(j.ID, 10),
				strings.NewReader(`{"state":"failed"}`))
			req.Header.Set("JOB-TOKEN", j.Token)
			if resp, err := http.DefaultClient.Do(req); err == nil {
				resp.Body.Close()
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func runDirect(t *testing.T, g *directGitLab, token string) (int, error) {
	t.Helper()
	t.Setenv("HANDOVER_FAKE_RUNNER", "1")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(g.srv.URL)
	dir := t.TempDir()
	h := &handover{direct: true, token: token, upstream: u, runner: self,
		dir: filepath.Join(dir, "run"), user: "nobody", home: dir,
		grace: 5 * time.Second, killWait: 2 * time.Second}
	if err := os.Mkdir(h.dir, 0o700); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	var code int
	go func() { code, err = h.run(); close(done) }()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("run did not end")
	}
	if _, statErr := os.Stat(filepath.Join(h.dir, "config.toml")); !os.IsNotExist(statErr) {
		t.Error("the config holding the runner token was left behind")
	}
	return code, err
}

func TestDirectRunTakesOneJobAndExitsZeroOnAFailedJob(t *testing.T) {
	captureLog(t)
	g := newDirectGitLab(t, testPayload(t, 42, 600, ""))
	g.noJobs = 2
	code, err := runDirect(t, g, runnerToken)
	if err != nil || code != 0 {
		t.Fatalf("exit %d %v, want 0", code, err)
	}
	if n := g.jobRequests(); n != 3 {
		t.Fatalf("GitLab saw %d job requests, want 3 (two empty, one job)", n)
	}
}

func TestDirectRunWithARefusedToken(t *testing.T) {
	captureLog(t)
	g := newDirectGitLab(t, testPayload(t, 42, 600, ""))
	g.refuse = true
	code, err := runDirect(t, g, runnerToken)
	if err != nil || code != 1 {
		t.Fatalf("exit %d %v, want 1", code, err)
	}
}
