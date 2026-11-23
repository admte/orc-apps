// Command gitlab-runner-handover starts a stock gitlab-runner for the value in
// the token file, told apart by its shape. A value whose first non-blank
// character is `{` is a credential the host supplies; anything else is a runner
// token.
//
//   - {"mode":"persistent","url":…,"token":…}: a runner token for the GitLab at
//     url. It writes the runner's config.toml and replaces itself with
//     `gitlab-runner run`, a runner that takes jobs until it is stopped.
//   - {"mode":"job","url":…,"job":{…}}: one job as GitLab at url handed it to a
//     runner. It serves that job to the runner from a proxy on loopback, ends
//     the runner once the job is over, and exits with the job's outcome: 0
//     success, 1 failed, 2 canceled, 3 ended by GitLab.
//   - A runner token, with --ephemeral=false: as persistent, against --url.
//   - A runner token, with --ephemeral=true: the runner takes exactly one job
//     straight from GitLab through the same proxy, which passes its job
//     requests upstream until one answers with a job and answers every later
//     one itself. It prints the job's outcome and exits 0 once the job is over,
//     however it ended; it exits 1 only when GitLab refuses the token or the
//     runner cannot start.
//
// `capture` prints what the runner build says of itself when it asks for a job
// (version, revision, features), and takes no job.
//
// It never logs a request or response body, a query string, or a token.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/url"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const usage = `Usage:
  gitlab-runner-handover start --token-file=PATH [--url=URL] [options]
  gitlab-runner-handover capture --runner=PATH [--dir=DIR]
  gitlab-runner-handover end-jobs [--user=NAME]   kill every process of the job account

start options:
  --token-file=PATH   file holding a runner token, {"mode":"persistent","url":…,"token":…}
                      or {"mode":"job","url":…,"job":{…}}
  --url=URL           GitLab's address, http or https; for a runner token only
  --ephemeral=BOOL    true for one job, false for a runner that takes jobs until
                      stopped (default false)
  --runner=PATH       the gitlab-runner binary (default /usr/local/bin/gitlab-runner)
  --dir=DIR           root-only directory for config.toml (default /run/gitlab-runner)
  --state-dir=DIR     where this machine's runner system id is kept
                      (default /var/lib/gitlab-runner)
  --user=NAME         account jobs run as (default gitlab-runner)
  --home=DIR          that account's working directory (default /home/gitlab-runner)

Exit status of a supplied job: 0 success, 1 failed, 2 canceled, 3 ended by GitLab.
Exit status of one job taken with a runner token: 0 once the job is over, 1 when
GitLab refuses the token or the runner cannot start.
`

// Exit codes of a handed-over job.
const (
	exitSuccess  = 0
	exitFailed   = 1
	exitCanceled = 2
	exitEnded    = 3
)

// The token the handed-over runner's config carries. The proxy authenticates
// nothing with it: GitLab takes every proxied call by the job's own token.
const placeholderToken = "glrt-handover-placeholder"

var logger = log.New(os.Stderr, "", 0)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(64)
	}
	var err error
	code := 0
	switch os.Args[1] {
	case "start":
		code, err = cmdStart(os.Args[2:])
	case "end-jobs":
		err = cmdEndJobs(os.Args[2:])
	case "capture":
		err = cmdCapture(os.Args[2:], os.Stdout)
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		logger.Printf("error: %v", err)
		if code == 0 {
			code = 64
		}
	}
	os.Exit(code)
}

type startOptions struct {
	tokenFile string
	url       string
	ephemeral string
	runner    string
	dir       string
	stateDir  string
	user      string
	home      string
}

func parseStart(args []string) (startOptions, error) {
	var o startOptions
	fs := flag.NewFlagSet("start", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&o.tokenFile, "token-file", "", "")
	fs.StringVar(&o.url, "url", "", "")
	fs.StringVar(&o.ephemeral, "ephemeral", "false", "")
	fs.StringVar(&o.runner, "runner", "/usr/local/bin/gitlab-runner", "")
	fs.StringVar(&o.dir, "dir", "/run/gitlab-runner", "")
	fs.StringVar(&o.stateDir, "state-dir", "/var/lib/gitlab-runner", "")
	fs.StringVar(&o.user, "user", "gitlab-runner", "")
	fs.StringVar(&o.home, "home", "/home/gitlab-runner", "")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if fs.NArg() > 0 {
		return o, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	if o.tokenFile == "" {
		return o, errors.New("--token-file is required")
	}
	switch o.ephemeral {
	case "":
		o.ephemeral = "false"
	case "true", "false":
	default:
		return o, errors.New("--ephemeral must be true or false")
	}
	return o, nil
}

// credential is what the token file holds.
type credential struct {
	mode  string // "token" (a runner token as given), "persistent" or "job"
	url   string // GitLab's address, from a supplied credential; "" for a runner token
	token string // the runner token: given, or of a persistent credential
	job   *job   // a supplied job
}

// job is what the proxy needs of GitLab's job payload; raw is served unchanged.
type job struct {
	raw       []byte
	id        int64
	token     string
	timeout   time.Duration
	startedAt time.Time // zero when the payload does not say
}

// parseCredential reads the token file's value by its shape: a value whose
// first non-blank character is `{` is a supplied credential, anything else a
// runner token. No error repeats any of the value.
func parseCredential(raw []byte) (credential, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return credential{}, errors.New("the token file is empty")
	}
	if trimmed[0] != '{' {
		if bytes.ContainsFunc(trimmed, func(r rune) bool { return r <= ' ' || r == 0x7f }) {
			return credential{}, errors.New("the runner token contains a space or a control character")
		}
		return credential{mode: "token", token: string(trimmed)}, nil
	}
	var env struct {
		Mode  *string         `json:"mode"`
		URL   string          `json:"url"`
		Token string          `json:"token"`
		Job   json.RawMessage `json:"job"`
	}
	if err := json.Unmarshal(trimmed, &env); err != nil {
		return credential{}, errors.New("the credential is not valid JSON")
	}
	if env.Mode == nil {
		return credential{}, errors.New("the credential names no mode")
	}
	switch *env.Mode {
	case "persistent", "job":
	default:
		return credential{}, fmt.Errorf("credential mode %q is not supported by this version", *env.Mode)
	}
	if env.URL == "" {
		return credential{}, fmt.Errorf("the %s credential has no url", *env.Mode)
	}
	if *env.Mode == "persistent" {
		if env.Token == "" {
			return credential{}, errors.New("the persistent credential has no token")
		}
		if strings.ContainsFunc(env.Token, func(r rune) bool { return r <= ' ' || r == 0x7f }) {
			return credential{}, errors.New("the persistent credential's token contains a space or a control character")
		}
		return credential{mode: "persistent", url: env.URL, token: env.Token}, nil
	}
	j, err := parseJob(env.Job)
	if err != nil {
		return credential{}, err
	}
	return credential{mode: "job", url: env.URL, job: j}, nil
}

func parseJob(raw []byte) (*job, error) {
	var p struct {
		ID         *int64          `json:"id"`
		Token      string          `json:"token"`
		JobInfo    json.RawMessage `json:"job_info"`
		RunnerInfo struct {
			Timeout int64 `json:"timeout"`
		} `json:"runner_info"`
		Variables []struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		} `json:"variables"`
	}
	if len(raw) == 0 || raw[0] != '{' {
		return nil, errors.New("the job credential holds no job")
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, errors.New("the job is not valid JSON")
	}
	if p.ID == nil || p.Token == "" || len(p.JobInfo) == 0 {
		return nil, errors.New("the job credential's job lacks an id, token or job_info")
	}
	j := &job{raw: append([]byte(nil), raw...), id: *p.ID, token: p.Token, timeout: time.Hour}
	if p.RunnerInfo.Timeout > 0 {
		j.timeout = time.Duration(p.RunnerInfo.Timeout) * time.Second
	}
	for _, v := range p.Variables {
		if v.Key == "CI_JOB_STARTED_AT" {
			if t, err := time.Parse(time.RFC3339, v.Value); err == nil {
				j.startedAt = t
			}
		}
	}
	return j, nil
}

// deadline is when a job that has not ended is ended as failed: GitLab's own
// timeout for it, counted from when it was taken, plus the 15 minutes GitLab
// itself waits before it drops a timed-out job.
func (j *job) deadline(now time.Time) time.Time {
	start := j.startedAt
	if start.IsZero() || start.After(now) {
		start = now
	}
	return start.Add(j.timeout + 15*time.Minute)
}

func parseBaseURL(raw, what string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return nil, fmt.Errorf("%s must be an http or https address", what)
	}
	if u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		return nil, fmt.Errorf("%s must carry no query, fragment or user", what)
	}
	return u, nil
}

func cmdStart(args []string) (int, error) {
	o, err := parseStart(args)
	if err != nil {
		return 64, err
	}
	raw, err := os.ReadFile(o.tokenFile)
	if err != nil {
		return exitFailed, errors.New("cannot read the token file")
	}
	cred, err := parseCredential(raw)
	clear(raw)
	if err != nil {
		return exitFailed, err
	}
	// A supplied credential names its GitLab; --url is for a runner token.
	var upstream *url.URL
	if cred.mode == "token" {
		if o.url == "" {
			return 64, errors.New("--url is required with a runner token")
		}
		upstream, err = parseBaseURL(o.url, "--url")
	} else {
		upstream, err = parseBaseURL(cred.url, "the credential's url")
	}
	if err != nil {
		return exitFailed, err
	}
	switch {
	case cred.mode == "persistent" && o.ephemeral == "true":
		return exitFailed, errors.New("a persistent credential runs a runner that takes jobs until stopped; start it with --ephemeral=false")
	case cred.mode == "job" && o.ephemeral == "false":
		return exitFailed, errors.New("a job is run once; start it with --ephemeral=true")
	}
	if err := os.MkdirAll(o.dir, 0o700); err != nil {
		return exitFailed, err
	}
	if err := os.Chmod(o.dir, 0o700); err != nil {
		return exitFailed, err
	}
	if cred.job == nil && o.ephemeral == "false" {
		return exitFailed, runPersistent(o, upstream, cred.token)
	}
	uid, err := lookupUID(o.user)
	if err != nil {
		return exitFailed, err
	}
	h := &handover{
		jobUID:   uid,
		job:      cred.job,
		upstream: upstream,
		runner:   o.runner,
		dir:      o.dir,
		user:     o.user,
		home:     o.home,
		grace:    30 * time.Second,
		killWait: 10 * time.Second,
	}
	if cred.job == nil {
		// Direct: the runner's own token, and one system id per machine as
		// for a runner that takes jobs until stopped.
		h.direct = true
		h.token = cred.token
		if err := ensureSystemID(o.stateDir, o.dir); err != nil {
			return exitFailed, err
		}
	}
	return h.run()
}

// lookupUID is the uid of the account jobs run as, which must not be root.
func lookupUID(name string) (int, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return 0, fmt.Errorf("no account %s", name)
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil || uid <= 0 {
		return 0, fmt.Errorf("jobs cannot run as %s", name)
	}
	return uid, nil
}

// cmdEndJobs kills whatever jobs left running: a job runs in a session of its
// own, outside the runner's process group and the service's cgroup.
func cmdEndJobs(args []string) error {
	fs := flag.NewFlagSet("end-jobs", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	name := fs.String("user", "gitlab-runner", "")
	if err := fs.Parse(args); err != nil {
		return err
	}
	uid, err := lookupUID(*name)
	if err != nil {
		return err
	}
	killUser(uid)
	return nil
}

// runPersistent writes the config of a runner that holds the runner token and
// replaces this process with it, so the stop signal reaches the runner itself.
func runPersistent(o startOptions, upstream *url.URL, token string) error {
	name, _ := os.Hostname()
	if name == "" {
		name = "gitlab-runner"
	}
	if err := ensureSystemID(o.stateDir, o.dir); err != nil {
		return err
	}
	config := filepath.Join(o.dir, "config.toml")
	if err := writeConfig(config, runnerConfig{
		name: name, url: upstream.String(), token: token, home: o.home, concurrent: 1,
	}); err != nil {
		return err
	}
	logger.Printf("starting the runner name=%s url=%s", name, redact(upstream.String()))
	argv := []string{o.runner, "run", "--config", config, "--user", o.user,
		"--working-directory", o.home, "--service", "gitlab-runner"}
	return syscall.Exec(o.runner, argv, os.Environ())
}

// ensureSystemID gives this machine one runner system id that outlives the
// config directory (/run is emptied at boot), so GitLab lists one runner
// manager per machine. It is made at the first start, never at install, so
// machines copied from one installed disk each get their own.
func ensureSystemID(stateDir, configDir string) error {
	path := filepath.Join(stateDir, "system_id")
	id, err := os.ReadFile(path)
	if err != nil || !regexp.MustCompile(`^s_[0-9a-f]{12}$`).Match(bytes.TrimSpace(id)) {
		b := make([]byte, 6)
		if _, err := rand.Read(b); err != nil {
			return err
		}
		id = []byte("s_" + hex.EncodeToString(b))
		if err := os.MkdirAll(stateDir, 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, id, 0o644); err != nil {
			return err
		}
	}
	return os.WriteFile(filepath.Join(configDir, ".runner_system_id"), bytes.TrimSpace(id), 0o600)
}

type runnerConfig struct {
	name       string
	url        string
	token      string
	home       string
	concurrent int
	limit      int // jobs the runner takes at once; 0: no limit
}

// writeConfig writes a root-only config.toml for one shell-executor runner.
func writeConfig(path string, c runnerConfig) error {
	var b strings.Builder
	fmt.Fprintf(&b, "concurrent = %d\ncheck_interval = 0\nlog_level = \"info\"\nlog_format = \"text\"\n\n", c.concurrent)
	b.WriteString("[[runners]]\n")
	fmt.Fprintf(&b, "  name = %s\n", tomlString(c.name))
	fmt.Fprintf(&b, "  url = %s\n", tomlString(c.url))
	fmt.Fprintf(&b, "  token = %s\n", tomlString(c.token))
	if c.limit > 0 {
		fmt.Fprintf(&b, "  limit = %d\n", c.limit)
	}
	b.WriteString("  executor = \"shell\"\n  shell = \"bash\"\n")
	fmt.Fprintf(&b, "  builds_dir = %s\n", tomlString(filepath.Join(c.home, "builds")))
	fmt.Fprintf(&b, "  cache_dir = %s\n", tomlString(filepath.Join(c.home, "cache")))
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// tomlString quotes s as a TOML basic string.
func tomlString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, "\\u%04x", r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

var tokenPattern = regexp.MustCompile(`(glrt-|glcbt-|glpat-|glptt-|gitlab-ci-token:)[A-Za-z0-9_.\-]+`)

// redact removes anything shaped like a GitLab token from a log value.
func redact(s string) string {
	return tokenPattern.ReplaceAllString(s, "${1}[redacted]")
}
