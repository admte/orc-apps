package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

const (
	jobToken  = "glcbt-SECRETjobtoken0123456789"
	queryCred = "SECRETquerysignature"
)

// syncBuffer collects the shim's log lines.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// captureLog sends the logger to a buffer for one test and checks at its end
// that no secret reached it.
func captureLog(t *testing.T) *syncBuffer {
	t.Helper()
	buf := &syncBuffer{}
	logger.SetOutput(buf)
	t.Cleanup(func() {
		logger.SetOutput(os.Stderr)
		for _, secret := range []string{jobToken, queryCred, "SECRETrunnertoken"} {
			if strings.Contains(buf.String(), secret) {
				t.Errorf("log carries a secret %q:\n%s", secret, buf.String())
			}
		}
	})
	return buf
}

func testPayload(t *testing.T, id int64, timeout int, startedAt string) []byte {
	t.Helper()
	vars := []map[string]any{{"key": "CI_JOB_TOKEN", "value": jobToken, "masked": true}}
	if startedAt != "" {
		vars = append(vars, map[string]any{"key": "CI_JOB_STARTED_AT", "value": startedAt})
	}
	b, err := json.Marshal(map[string]any{
		"id": id, "token": jobToken,
		"job_info":    map[string]any{"id": id, "name": "build"},
		"runner_info": map[string]any{"timeout": timeout},
		"git_info":    map[string]any{"repo_url": "https://gitlab-ci-token:" + jobToken + "@example.test/p.git"},
		"variables":   vars,
	})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func testJob(t *testing.T) *job {
	t.Helper()
	cred, err := parseCredential(testPayload(t, 42, 3600, ""))
	if err != nil || cred.job == nil {
		t.Fatalf("payload: %v", err)
	}
	return cred.job
}

// fakeGitLab answers the runner's calls for job 42 from a script of answers.
type fakeGitLab struct {
	mu      sync.Mutex
	hits    []string
	putCode []int
	putJS   []string
	srv     *httptest.Server
}

func newFakeGitLab(t *testing.T, extra http.HandlerFunc) *fakeGitLab {
	f := &fakeGitLab{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.hits = append(f.hits, r.Method+" "+r.URL.RequestURI())
		f.mu.Unlock()
		if r.Header.Get("JOB-TOKEN") != jobToken && r.URL.Path != "/redirect" && r.URL.Path != "/stream" && r.URL.Path != "/upload" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if extra != nil && r.URL.Path != "/api/v4/jobs/42" && r.URL.Path != "/api/v4/jobs/42/trace" {
			extra(w, r)
			return
		}
		switch {
		case r.Method == http.MethodPut && r.URL.Path == "/api/v4/jobs/42":
			f.mu.Lock()
			code, js := 200, "success"
			if len(f.putCode) > 0 {
				code, js = f.putCode[0], f.putJS[0]
				f.putCode, f.putJS = f.putCode[1:], f.putJS[1:]
			}
			f.mu.Unlock()
			if js != "" {
				w.Header().Set("Job-Status", js)
			}
			w.WriteHeader(code)
		case r.Method == http.MethodPatch && r.URL.Path == "/api/v4/jobs/42/trace":
			f.mu.Lock()
			code := 202
			if len(f.putCode) > 0 && strings.HasPrefix(f.putJS[0], "trace") {
				code = f.putCode[0]
				if js, ok := strings.CutPrefix(f.putJS[0], "trace:"); ok {
					w.Header().Set("Job-Status", js)
				}
				f.putCode, f.putJS = f.putCode[1:], f.putJS[1:]
			}
			f.mu.Unlock()
			w.WriteHeader(code)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeGitLab) script(answers ...any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := 0; i < len(answers); i += 2 {
		f.putCode = append(f.putCode, answers[i].(int))
		f.putJS = append(f.putJS, answers[i+1].(string))
	}
}

func (f *fakeGitLab) hitCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.hits)
}

func startProxy(t *testing.T, j *job, upstream string) (*httptest.Server, chan event) {
	t.Helper()
	u, err := url.Parse(upstream)
	if err != nil {
		t.Fatal(err)
	}
	tr, err := newTransport("")
	if err != nil {
		t.Fatal(err)
	}
	events := make(chan event, 16)
	srv := httptest.NewServer(newProxy(j, u, tr, events))
	t.Cleanup(srv.Close)
	return srv, events
}

var noRedirect = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error {
	return http.ErrUseLastResponse
}}

func do(t *testing.T, method, u string, body io.Reader, hdr map[string]string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, u, body)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := noRedirect.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func put(t *testing.T, base string) *http.Response {
	resp := do(t, http.MethodPut, base+"/api/v4/jobs/42", strings.NewReader(`{"token":"`+jobToken+`","state":"success"}`),
		map[string]string{"JOB-TOKEN": jobToken, "Content-Type": "application/json"})
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return resp
}

func nextEvent(t *testing.T, events chan event) (event, bool) {
	t.Helper()
	select {
	case ev := <-events:
		return ev, true
	case <-time.After(200 * time.Millisecond):
		return event{}, false
	}
}

func TestJobRequestServedOnceThenNoContent(t *testing.T) {
	captureLog(t)
	f := newFakeGitLab(t, nil)
	j := testJob(t)
	srv, _ := startProxy(t, j, f.srv.URL)

	var created atomic.Int32
	var wg sync.WaitGroup
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp := do(t, http.MethodPost, srv.URL+"/api/v4/jobs/request", strings.NewReader(`{"token":"glrt-x"}`), nil)
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			switch resp.StatusCode {
			case http.StatusCreated:
				created.Add(1)
				if !bytes.Equal(body, j.raw) {
					t.Errorf("payload changed on the way")
				}
			case http.StatusNoContent:
			default:
				t.Errorf("status %d", resp.StatusCode)
			}
		}()
	}
	wg.Wait()
	if created.Load() != 1 {
		t.Fatalf("payload served %d times, want once", created.Load())
	}
	if f.hitCount() != 0 {
		t.Fatalf("job requests reached GitLab: %v", f.hits)
	}
}

func TestVerifyAnsweredLocally(t *testing.T) {
	captureLog(t)
	f := newFakeGitLab(t, nil)
	srv, _ := startProxy(t, testJob(t), f.srv.URL)
	resp := do(t, http.MethodPost, srv.URL+"/api/v4/runners/verify", strings.NewReader(`{"token":"glrt-x"}`), nil)
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"id":0`) {
		t.Fatalf("verify: %d %s", resp.StatusCode, body)
	}
	if f.hitCount() != 0 {
		t.Fatalf("verify reached GitLab: %v", f.hits)
	}
}

func TestVerdictIsTheLastFinalStatus(t *testing.T) {
	captureLog(t)
	f := newFakeGitLab(t, nil)
	srv, events := startProxy(t, testJob(t), f.srv.URL)
	// gitlab.com answers the final PUT with 202 running, then 200 success.
	f.script(202, "running", 200, "success", 403, "")
	if put(t, srv.URL).StatusCode != 202 {
		t.Fatal("202 not passed through")
	}
	if ev, ok := nextEvent(t, events); ok {
		t.Fatalf("202 running gave an event %+v", ev)
	}
	put(t, srv.URL)
	if ev, ok := nextEvent(t, events); !ok || ev.verdict != "success" {
		t.Fatalf("no success verdict: %+v %v", ev, ok)
	}
	// A 403 after a verdict is ignored.
	if put(t, srv.URL).StatusCode != 403 {
		t.Fatal("403 not passed through")
	}
	if ev, ok := nextEvent(t, events); ok {
		t.Fatalf("403 after the verdict gave an event %+v", ev)
	}
	// A later, different final status replaces it.
	f.script(200, "failed")
	put(t, srv.URL)
	if ev, ok := nextEvent(t, events); !ok || ev.verdict != "failed" {
		t.Fatalf("last final status not taken: %+v", ev)
	}
}

func TestCanceledAndCancelingStatuses(t *testing.T) {
	captureLog(t)
	f := newFakeGitLab(t, nil)
	srv, events := startProxy(t, testJob(t), f.srv.URL)
	f.script(200, "canceling", 200, "canceled")
	put(t, srv.URL)
	if ev, ok := nextEvent(t, events); ok {
		t.Fatalf("canceling is not final, got %+v", ev)
	}
	put(t, srv.URL)
	if ev, ok := nextEvent(t, events); !ok || ev.verdict != "canceled" {
		t.Fatalf("canceled: %+v", ev)
	}
}

func TestForbiddenWithoutVerdictEndsTheJob(t *testing.T) {
	for _, viaTrace := range []bool{false, true} {
		t.Run(fmt.Sprintf("trace=%v", viaTrace), func(t *testing.T) {
			captureLog(t)
			f := newFakeGitLab(t, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusForbidden)
			})
			srv, events := startProxy(t, testJob(t), f.srv.URL)
			// A 403 on some other call says nothing about this job.
			resp := do(t, http.MethodGet, srv.URL+"/api/v4/jobs/7/artifacts", nil, map[string]string{"JOB-TOKEN": jobToken})
			resp.Body.Close()
			if ev, ok := nextEvent(t, events); ok {
				t.Fatalf("unrelated 403 gave %+v", ev)
			}
			if viaTrace {
				f.script(403, "trace")
				resp := do(t, http.MethodPatch, srv.URL+"/api/v4/jobs/42/trace?debug_trace=false", strings.NewReader("log"),
					map[string]string{"JOB-TOKEN": jobToken, "Content-Range": "0-2"})
				resp.Body.Close()
			} else {
				f.script(403, "")
				put(t, srv.URL)
			}
			if ev, ok := nextEvent(t, events); !ok || !ev.ended {
				t.Fatalf("403 with no verdict did not end the job: %+v", ev)
			}
		})
	}
}

func TestRedirectPassedThroughUnfollowed(t *testing.T) {
	captureLog(t)
	var cdnHits atomic.Int32
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { cdnHits.Add(1) }))
	defer cdn.Close()
	location := cdn.URL + "/artifact.zip?X-Amz-Signature=" + queryCred
	f := newFakeGitLab(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", location)
		w.WriteHeader(http.StatusFound)
	})
	srv, _ := startProxy(t, testJob(t), f.srv.URL)
	resp := do(t, http.MethodGet, srv.URL+"/api/v4/jobs/7/artifacts?direct_download=true", nil, map[string]string{"JOB-TOKEN": jobToken})
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != location {
		t.Fatalf("redirect changed: %d %q", resp.StatusCode, resp.Header.Get("Location"))
	}
	if cdnHits.Load() != 0 {
		t.Fatal("the shim followed the redirect")
	}
}

func TestRequestAndHeadersReachGitLabUnchanged(t *testing.T) {
	captureLog(t)
	var got http.Header
	var gotURI string
	var gotBody []byte
	f := newFakeGitLab(t, func(w http.ResponseWriter, r *http.Request) {
		got, gotURI = r.Header.Clone(), r.URL.RequestURI()
		gotBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Encoding", "gzip")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte("gzipped-bytes"))
	})
	srv, _ := startProxy(t, testJob(t), f.srv.URL)
	resp := do(t, http.MethodPost, srv.URL+"/api/v4/jobs/42/artifacts?artifact_format=zip&expire_in=1+day",
		strings.NewReader("zipdata"), map[string]string{"JOB-TOKEN": jobToken, "Accept-Encoding": "gzip"})
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if gotURI != "/api/v4/jobs/42/artifacts?artifact_format=zip&expire_in=1+day" || string(gotBody) != "zipdata" {
		t.Fatalf("request changed: %s %q", gotURI, gotBody)
	}
	if got.Get("Accept-Encoding") != "gzip" || got.Get("X-Forwarded-For") != "" {
		t.Fatalf("headers changed: %v", got)
	}
	if resp.StatusCode != 201 || string(body) != "gzipped-bytes" || resp.Header.Get("Content-Encoding") != "gzip" {
		t.Fatalf("response changed: %d %q %v", resp.StatusCode, body, resp.Header)
	}
}

func TestBodiesStreamBothWays(t *testing.T) {
	captureLog(t)
	firstIn := make(chan string, 1)
	release := make(chan struct{})
	f := newFakeGitLab(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/upload":
			buf := make([]byte, 5)
			_, _ = io.ReadFull(r.Body, buf)
			firstIn <- string(buf) // seen before the client has sent the rest
			_, _ = io.Copy(io.Discard, r.Body)
		case "/stream":
			_, _ = w.Write([]byte("part1"))
			w.(http.Flusher).Flush()
			<-release
			_, _ = w.Write([]byte("part2"))
		}
	})
	srv, _ := startProxy(t, testJob(t), f.srv.URL)

	// Upload: GitLab sees the first bytes while the body is still open.
	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() {
		resp := do(t, http.MethodPost, srv.URL+"/upload", pr, nil)
		resp.Body.Close()
		close(done)
	}()
	_, _ = pw.Write([]byte("chunk"))
	select {
	case s := <-firstIn:
		if s != "chunk" {
			t.Fatalf("got %q", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("request body was buffered, not streamed")
	}
	pw.Close()
	<-done

	// Download: the client reads the first part before GitLab sends the rest.
	resp := do(t, http.MethodGet, srv.URL+"/stream", nil, nil)
	defer resp.Body.Close()
	buf := make([]byte, 5)
	readDone := make(chan error, 1)
	go func() { _, err := io.ReadFull(resp.Body, buf); readDone <- err }()
	select {
	case err := <-readDone:
		if err != nil || string(buf) != "part1" {
			t.Fatalf("got %q %v", buf, err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("response body was buffered, not streamed")
	}
	close(release)
	rest, _ := io.ReadAll(resp.Body)
	if string(rest) != "part2" {
		t.Fatalf("rest %q", rest)
	}
}

func TestUpstreamDownLogsNoQuery(t *testing.T) {
	buf := captureLog(t)
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL
	dead.Close()
	srv, _ := startProxy(t, testJob(t), deadURL)
	resp := do(t, http.MethodGet, srv.URL+"/api/v4/jobs/42/artifacts?sig="+queryCred, nil, map[string]string{"JOB-TOKEN": jobToken})
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if !strings.Contains(buf.String(), "upstream error method=GET path=/api/v4/jobs/42/artifacts") {
		t.Fatalf("log: %s", buf.String())
	}
}

func TestNoSecretInLogsOverAWholeJob(t *testing.T) {
	buf := captureLog(t)
	f := newFakeGitLab(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	srv, events := startProxy(t, testJob(t), f.srv.URL)
	resp := do(t, http.MethodPost, srv.URL+"/api/v4/jobs/request", strings.NewReader(`{"token":"glrt-SECRETrunnertoken"}`), nil)
	resp.Body.Close()
	for _, p := range []string{"/api/v4/jobs/42/artifacts?token=" + jobToken, "/api/v4/jobs/" + jobToken} {
		resp := do(t, http.MethodGet, srv.URL+p, nil, map[string]string{"JOB-TOKEN": jobToken})
		resp.Body.Close()
	}
	put(t, srv.URL)
	nextEvent(t, events)
	// The access line is written once the answer has gone out.
	for i := 0; i < 100 && !strings.Contains(buf.String(), "PUT /api/v4/jobs/42 200"); i++ {
		time.Sleep(10 * time.Millisecond)
	}
	if !strings.Contains(buf.String(), "PUT /api/v4/jobs/42 200") {
		t.Fatalf("expected an access line:\n%s", buf.String())
	}
}

// sleeper is a stand-in runner: a process group that lives until it is ended.
func sleeper(t *testing.T) (int, chan error) {
	t.Helper()
	cmd := exec.Command("sleep", "60")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	t.Cleanup(func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) })
	return cmd.Process.Pid, exited
}

func superviseWith(t *testing.T, j *job, pid int, exited chan error, events chan event, sigs chan os.Signal) (int, time.Duration) {
	t.Helper()
	h := &handover{job: j, grace: 300 * time.Millisecond, killWait: 2 * time.Second, now: time.Now}
	start := time.Now()
	code := h.supervise(pid, exited, events, sigs)
	return code, time.Since(start)
}

func alive(pid int) bool { return syscall.Kill(pid, 0) == nil }

func TestSuperviseExitCodes(t *testing.T) {
	captureLog(t)
	cases := []struct {
		name  string
		event event
		want  int
	}{
		{"success", event{verdict: "success"}, exitSuccess},
		{"failed", event{verdict: "failed"}, exitFailed},
		{"canceled", event{verdict: "canceled"}, exitCanceled},
		{"ended by GitLab", event{ended: true}, exitEnded},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pid, exited := sleeper(t)
			events := make(chan event, 1)
			events <- c.event
			code, _ := superviseWith(t, testJob(t), pid, exited, events, make(chan os.Signal))
			if code != c.want {
				t.Fatalf("exit %d, want %d", code, c.want)
			}
			// The runner is ended in every case: after the verdict's grace, or
			// at once for a job GitLab ended.
			if alive(pid) {
				t.Fatal("runner still running")
			}
		})
	}
}

func TestSuperviseRunnerExitAfterVerdictIsImmediate(t *testing.T) {
	captureLog(t)
	exited := make(chan error, 1)
	events := make(chan event, 1)
	events <- event{verdict: "success"}
	go func() { time.Sleep(20 * time.Millisecond); exited <- nil }()
	h := &handover{job: testJob(t), grace: time.Hour, killWait: time.Second, now: time.Now}
	// pid 0 would signal this test's own group: use one that cannot exist.
	code := h.supervise(1<<22+1, exited, events, make(chan os.Signal))
	if code != exitSuccess {
		t.Fatalf("exit %d", code)
	}
}

func TestSuperviseRunnerExitWithoutVerdictIsFailed(t *testing.T) {
	captureLog(t)
	exited := make(chan error, 1)
	exited <- nil // the runner exits 0 whatever happened
	h := &handover{job: testJob(t), grace: time.Second, killWait: time.Second, now: time.Now}
	if code := h.supervise(1<<22+1, exited, make(chan event), make(chan os.Signal)); code != exitFailed {
		t.Fatalf("exit %d, want %d", code, exitFailed)
	}
}

func TestSuperviseDeadline(t *testing.T) {
	captureLog(t)
	// Taken long enough ago that take + timeout + 15 min is 200 ms from now.
	started := time.Now().Add(-(60*time.Second + 15*time.Minute) + 200*time.Millisecond).UTC()
	cred, err := parseCredential(testPayload(t, 42, 60, started.Format(time.RFC3339Nano)))
	if err != nil {
		t.Fatal(err)
	}
	pid, exited := sleeper(t)
	code, took := superviseWith(t, cred.job, pid, exited, make(chan event), make(chan os.Signal))
	if code != exitFailed || took > 5*time.Second {
		t.Fatalf("exit %d after %s", code, took)
	}
	if alive(pid) {
		t.Fatal("runner still running")
	}
}

func TestDeadlineCountsFromTheTake(t *testing.T) {
	now := time.Date(2026, 11, 21, 18, 0, 0, 0, time.UTC)
	cred, _ := parseCredential(testPayload(t, 1, 600, "2026-11-21T17:36:51Z"))
	want := time.Date(2026, 11, 21, 18, 1, 51, 0, time.UTC)
	if got := cred.job.deadline(now); !got.Equal(want) {
		t.Fatalf("deadline %s, want %s", got, want)
	}
	// No take time: count from now.
	cred, _ = parseCredential(testPayload(t, 1, 600, ""))
	if got := cred.job.deadline(now); !got.Equal(now.Add(25 * time.Minute)) {
		t.Fatalf("deadline %s", got)
	}
}

func TestSuperviseStopSignal(t *testing.T) {
	captureLog(t)
	pid, exited := sleeper(t)
	sigs := make(chan os.Signal, 1)
	sigs <- syscall.SIGTERM
	code, _ := superviseWith(t, testJob(t), pid, exited, make(chan event), sigs)
	if code != 128+int(syscall.SIGTERM) {
		t.Fatalf("exit %d", code)
	}
}

func TestParseCredential(t *testing.T) {
	cred, err := parseCredential([]byte(`{"mode":"persistent","token":"glrt-SECRETrunnertoken"}`))
	if err != nil || cred.token != "glrt-SECRETrunnertoken" || cred.job != nil {
		t.Fatalf("persistent: %+v %v", cred, err)
	}
	for _, bad := range []string{
		`{"mode":"jit","token":"x"}`,
		`{"mode":"persistent"}`,
		`{"mode":"persistent","token":"a\nb"}`,
		`{"id":1,"token":"x"}`,
		`glrt-plain`,
		`{`,
	} {
		if _, err := parseCredential([]byte(bad)); err == nil {
			t.Errorf("accepted %q", bad)
		} else if strings.Contains(err.Error(), "glrt-") || strings.Contains(err.Error(), `"x"`) {
			t.Errorf("error repeats the credential: %v", err)
		}
	}
}

func TestStartRefusesAMismatchedMode(t *testing.T) {
	captureLog(t)
	dir := t.TempDir()
	file := filepath.Join(dir, "job")
	for _, c := range []struct{ content, ephemeral string }{
		{`{"mode":"persistent","token":"glrt-SECRETrunnertoken"}`, "true"},
		{string(testPayload(t, 1, 60, "")), "false"},
	} {
		if err := os.WriteFile(file, []byte(c.content), 0o600); err != nil {
			t.Fatal(err)
		}
		code, err := cmdStart([]string{"--job-file=" + file, "--url=https://gitlab.example", "--ephemeral=" + c.ephemeral,
			"--dir=" + filepath.Join(dir, "run"), "--runner=/nonexistent"})
		if err == nil || code == 0 {
			t.Errorf("ephemeral=%s accepted", c.ephemeral)
		}
	}
}

func TestWriteConfigIsRootOnlyAndQuoted(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")
	if err := writeConfig(path, runnerConfig{name: `a"b\c`, url: "https://g.example", token: "glrt-SECRETrunnertoken",
		home: "/home/gitlab-runner", concurrent: 1, limit: 1}); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v %v", st.Mode(), err)
	}
	b, _ := os.ReadFile(path)
	for _, want := range []string{`name = "a\"b\\c"`, `token = "glrt-SECRETrunnertoken"`, `limit = 1`, `executor = "shell"`} {
		if !strings.Contains(string(b), want) {
			t.Errorf("config lacks %s:\n%s", want, b)
		}
	}
	if tomlString("x\ny") != `"x\u000ay"` {
		t.Errorf("control character not escaped: %s", tomlString("x\ny"))
	}
}

func TestSystemIDIsKeptPerMachine(t *testing.T) {
	state, conf := t.TempDir(), t.TempDir()
	if err := ensureSystemID(state, conf); err != nil {
		t.Fatal(err)
	}
	first, _ := os.ReadFile(filepath.Join(conf, ".runner_system_id"))
	if err := ensureSystemID(state, conf); err != nil {
		t.Fatal(err)
	}
	second, _ := os.ReadFile(filepath.Join(conf, ".runner_system_id"))
	if len(first) != 14 || !bytes.Equal(first, second) {
		t.Fatalf("system id %q then %q", first, second)
	}
	other := t.TempDir()
	_ = ensureSystemID(other, conf)
	third, _ := os.ReadFile(filepath.Join(conf, ".runner_system_id"))
	if bytes.Equal(first, third) {
		t.Fatal("two machines got one system id")
	}
}

func TestCaptureRecordsInfoWithoutToken(t *testing.T) {
	c := &captureHandler{got: make(chan capturedInfo, 1)}
	srv := httptest.NewServer(c)
	defer srv.Close()
	resp := do(t, http.MethodPost, srv.URL+"/api/v4/jobs/request",
		strings.NewReader(`{"token":"glrt-SECRETrunnertoken","info":{"version":"19.6.0","revision":"9e4c6b50","features":{"cancelable":true}}}`), nil)
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("status %d", resp.StatusCode)
	}
	info := <-c.got
	out, _ := json.Marshal(info)
	if string(out) != `{"version":"19.6.0","revision":"9e4c6b50","features":{"cancelable":true}}` {
		t.Fatalf("captured %s", out)
	}
}

func TestGraceEndsARunnerThatIgnoresTheStop(t *testing.T) {
	captureLog(t)
	cmd := exec.Command("sh", "-c", `trap "" QUIT; echo ready; sleep 60`)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	// The stop is sent only once the stand-in ignores it.
	if _, err := io.ReadFull(out, make([]byte, 6)); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	t.Cleanup(func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) })
	events := make(chan event, 1)
	events <- event{verdict: "failed"}
	code, took := superviseWith(t, testJob(t), cmd.Process.Pid, exited, events, make(chan os.Signal))
	if code != exitFailed || took < 300*time.Millisecond {
		t.Fatalf("exit %d after %s", code, took)
	}
	if alive(cmd.Process.Pid) {
		t.Fatal("runner still running after the grace")
	}
}

func TestVerdictAfterAStopSignalStillDecides(t *testing.T) {
	captureLog(t)
	exited := make(chan error, 1)
	events := make(chan event, 1)
	sigs := make(chan os.Signal, 1)
	sigs <- syscall.SIGQUIT
	go func() {
		time.Sleep(50 * time.Millisecond)
		events <- event{verdict: "success"}
		time.Sleep(50 * time.Millisecond)
		exited <- nil
	}()
	h := &handover{job: testJob(t), grace: time.Hour, killWait: time.Second, now: time.Now}
	if code := h.supervise(1<<22+1, exited, events, sigs); code != exitSuccess {
		t.Fatalf("exit %d, want %d", code, exitSuccess)
	}
}

func TestRunnerAskingForMoreWorkWithoutVerdict(t *testing.T) {
	captureLog(t)
	f := newFakeGitLab(t, nil)
	srv, events := startProxy(t, testJob(t), f.srv.URL)
	request := func() {
		resp := do(t, http.MethodPost, srv.URL+"/api/v4/jobs/request", strings.NewReader(`{}`), nil)
		resp.Body.Close()
	}
	request()
	if ev, ok := nextEvent(t, events); ok {
		t.Fatalf("the hand-over itself gave %+v", ev)
	}
	request()
	if ev, ok := nextEvent(t, events); !ok || !ev.idle {
		t.Fatalf("no idle event: %+v", ev)
	}

	// Once GitLab gave a verdict, asking for work is the runner winding down.
	srv2, events2 := startProxy(t, testJob(t), f.srv.URL)
	resp := do(t, http.MethodPost, srv2.URL+"/api/v4/jobs/request", strings.NewReader(`{}`), nil)
	resp.Body.Close()
	put(t, srv2.URL)
	nextEvent(t, events2)
	resp = do(t, http.MethodPost, srv2.URL+"/api/v4/jobs/request", strings.NewReader(`{}`), nil)
	resp.Body.Close()
	if ev, ok := nextEvent(t, events2); ok {
		t.Fatalf("request after the verdict gave %+v", ev)
	}

	pid, exited := sleeper(t)
	ev := make(chan event, 1)
	ev <- event{idle: true}
	code, _ := superviseWith(t, testJob(t), pid, exited, ev, make(chan os.Signal))
	if code != exitFailed || alive(pid) {
		t.Fatalf("exit %d, runner alive %v", code, alive(pid))
	}
}

func TestForbiddenWithAFinalJobStatusIsNoVerdict(t *testing.T) {
	// GitLab sets Job-Status on its 403s too; only a 2xx answer is a verdict.
	for _, via := range []string{"put", "trace", "artifacts"} {
		t.Run(via, func(t *testing.T) {
			captureLog(t)
			f := newFakeGitLab(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Job-Status", "success")
				w.WriteHeader(http.StatusForbidden)
			})
			srv, events := startProxy(t, testJob(t), f.srv.URL)
			switch via {
			case "put":
				f.script(403, "failed")
				put(t, srv.URL)
			case "trace":
				f.script(403, "trace:canceled")
				resp := do(t, http.MethodPatch, srv.URL+"/api/v4/jobs/42/trace", strings.NewReader("log"),
					map[string]string{"JOB-TOKEN": jobToken, "Content-Range": "0-2"})
				resp.Body.Close()
			case "artifacts":
				resp := do(t, http.MethodPost, srv.URL+"/api/v4/jobs/42/artifacts", strings.NewReader("zip"),
					map[string]string{"JOB-TOKEN": jobToken})
				resp.Body.Close()
			}
			if ev, ok := nextEvent(t, events); !ok || !ev.ended || ev.verdict != "" {
				t.Fatalf("403 with Job-Status gave %+v, want ended", ev)
			}
		})
	}
}

func TestEventIsQueuedBeforeTheRunnerSeesTheAnswer(t *testing.T) {
	captureLog(t)
	f := newFakeGitLab(t, nil)
	srv, events := startProxy(t, testJob(t), f.srv.URL)
	put(t, srv.URL)
	select {
	case ev := <-events:
		if ev.verdict != "success" {
			t.Fatalf("event %+v", ev)
		}
	default:
		t.Fatal("the runner had the answer before the verdict was queued")
	}
}

func TestPendingVerdictWinsOverTheRunnersExit(t *testing.T) {
	captureLog(t)
	for _, c := range []struct {
		ev   event
		want int
	}{{event{verdict: "canceled"}, exitCanceled}, {event{ended: true}, exitEnded}} {
		h := &handover{job: testJob(t), grace: time.Hour, killWait: time.Second, now: time.Now}
		// Both are ready; whichever select picks, the verdict decides.
		for range 20 {
			e2, x2 := make(chan event, 1), make(chan error, 1)
			e2 <- c.ev
			x2 <- nil
			if code := h.supervise(1<<22+1, x2, e2, make(chan os.Signal)); code != c.want {
				t.Fatalf("exit %d, want %d", code, c.want)
			}
		}
	}
}

func TestDeadlineKeepsAVerdictAlreadyIn(t *testing.T) {
	captureLog(t)
	started := time.Now().Add(-(60*time.Second + 15*time.Minute) + 300*time.Millisecond).UTC()
	cred, err := parseCredential(testPayload(t, 42, 60, started.Format(time.RFC3339Nano)))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", "-c", `trap "" QUIT; echo ready; sleep 60`)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(out, make([]byte, 6)); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	t.Cleanup(func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) })
	events := make(chan event, 1)
	events <- event{verdict: "success"}
	h := &handover{job: cred.job, grace: time.Hour, killWait: time.Second, now: time.Now}
	if code := h.supervise(cmd.Process.Pid, exited, events, make(chan os.Signal)); code != exitSuccess {
		t.Fatalf("exit %d, want %d", code, exitSuccess)
	}
}
