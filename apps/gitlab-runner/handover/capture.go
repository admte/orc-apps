package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// capturedInfo is what a runner build says of itself when it asks for a job.
type capturedInfo struct {
	Version  string          `json:"version"`
	Revision string          `json:"revision"`
	Features json.RawMessage `json:"features"`
}

// captureHandler records the first job request's `info` and answers every
// request with "no job". The request's token is never kept.
type captureHandler struct {
	got chan capturedInfo
}

func (c *captureHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost && r.URL.Path == "/api/v4/jobs/request" {
		var req struct {
			Info capturedInfo `json:"info"`
		}
		err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req)
		w.WriteHeader(http.StatusNoContent)
		if err == nil && req.Info.Version != "" {
			select {
			case c.got <- req.Info:
			default:
			}
		}
		return
	}
	if r.Method == http.MethodPost && r.URL.Path == "/api/v4/runners/verify" {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":0,"token":"`+placeholderToken+`","token_expires_at":null}`)
		return
	}
	w.WriteHeader(http.StatusNotFound)
}

// cmdCapture runs the runner against a local endpoint that takes no job, and
// prints its version, revision and features as one JSON object.
func cmdCapture(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("capture", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	runner := fs.String("runner", "/usr/local/bin/gitlab-runner", "")
	dir := fs.String("dir", "", "")
	if err := fs.Parse(args); err != nil {
		return err
	}
	work := *dir
	if work == "" {
		var err error
		if work, err = os.MkdirTemp("", "gitlab-runner-capture-"); err != nil {
			return err
		}
		defer os.RemoveAll(work)
	}
	c := &captureHandler{got: make(chan capturedInfo, 1)}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: c, ReadHeaderTimeout: 30 * time.Second}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()
	config := filepath.Join(work, "config.toml")
	if err := writeConfig(config, runnerConfig{
		name: "capture", url: "http://" + ln.Addr().String(), token: placeholderToken,
		home: work, concurrent: 1,
	}); err != nil {
		return err
	}
	cmd := exec.Command(*runner, "run-single", "--config", config, "--runner", "capture",
		"--max-builds", "1")
	cmd.Dir = work
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("cannot start the runner: %w", err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	defer func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-exited
	}()
	select {
	case info := <-c.got:
		return json.NewEncoder(out).Encode(info)
	case err := <-exited:
		exited <- err
		return fmt.Errorf("the runner exited before asking for a job: %v", exitText(err))
	case <-time.After(60 * time.Second):
		return errors.New("the runner asked for no job within 60 s")
	}
}
