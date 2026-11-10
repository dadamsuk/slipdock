package executor

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// container runs each of a job's processes in a short-lived Docker or
// Podman container (#2577, W-2544 part 6), from the image the runner
// names, which runs only if it matches the machine's allow-list.
//
// What the container sees of the machine is what is mounted, each at the
// path it has here: the job's directory (or its repository) and the
// repository a worktree belongs to, read-write; the agent's and the CLI's
// logins, read-only; and the machine's slipdock CLI, read-only, over the
// image's; and, for the agent alone, a fresh directory of the job's own
// at the home's .claude/projects, for its transcripts (#2625). Its home
// (the daemon's home's path) is an empty tmpfs, so
// nothing of the home is there but what is mounted. A mount of the home,
// of a directory holding it, of the daemon's own directory or of the
// container runtime's socket is refused. Only the job's own variables
// and the ones the local file names pass in, never the daemon's
// SLIPDOCK_* ones. The network is off when the runner asks.
//
// The daemon's own git and gh for the runner (its worktrees, the merge)
// and the runner's hooks run in the same image with the same walls, as
// under confined: a job may plant git config in its repository.
type container struct {
	s       Settings
	runtime string
	mu      sync.Mutex
	top     string
}

func newContainer(s Settings) *container {
	if s.Pull == "" {
		s.Pull = "never"
	}
	return &container{s: s}
}

func (c *container) Name() string { return Container }
func (c *container) Home() string { return c.s.Home }

// Files: the daemon reads nothing the job could have written. A job can
// put a link anywhere in what it may write, and following it would read
// the machine's files for it. Its transcripts are read from the
// directory made for them, through Beneath (#2625).
func (c *container) Files() Files { return noFiles{} }

// TranscriptsAt is where a Proc's Transcripts directory is mounted in the
// container: Claude Code's projects directory, in the home.
func TranscriptsAt(home string) string { return filepath.Join(home, ".claude", "projects") }

// Pulls are the pull policies a machine may set (container.pull).
var Pulls = []string{"never", "missing", "always"}

// reservedEnv can't be passed in from the daemon: the container's own.
var reservedEnv = map[string]bool{"HOME": true, "PATH": true, "PWD": true, "USER": true, "LOGNAME": true,
	"SHELL": true, "TMPDIR": true, "HOSTNAME": true}

var envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)

// ValidPassEnv says why name can't be one of the daemon's variables a
// container job gets (container.env), or nil. The daemon's SLIPDOCK_*
// variables never pass: its tokens and the job variables are its own.
func ValidPassEnv(name string) error {
	return validEnv(name, "%s: the daemon's SLIPDOCK_* variables never pass into a container", "%s is the container's own")
}

// ValidJobEnv says why name can't be a variable the machine sets for a
// runner's jobs (the local file's runners.<name>.env), or nil. The
// SLIPDOCK_* variables are the daemon's to set, and HOME, PATH and the
// like are each executor's own: one set here would be dropped by some
// executors and override the others'.
func ValidJobEnv(name string) error {
	return validEnv(name, "%s: the SLIPDOCK_* variables are the daemon's to set", "%s is the executor's own")
}

// validEnv is the one check both make, each in its own words.
func validEnv(name, daemons, reserved string) error {
	switch {
	case !envName.MatchString(name):
		return fmt.Errorf("%q is not a variable's name", name)
	case strings.HasPrefix(strings.ToUpper(name), "SLIPDOCK_"):
		return fmt.Errorf(daemons, name)
	case reservedEnv[strings.ToUpper(name)]:
		return fmt.Errorf(reserved, name)
	}
	return nil
}

// DefaultLogin is what is mounted read-only when the local file names
// nothing: the agent's login and the slipdock CLI's, under home. The ones
// that aren't there are left out.
func DefaultLogin(home, agent string) []string {
	var out []string
	switch agent {
	case "claude":
		out = append(out, filepath.Join(home, ".claude", ".credentials.json"), filepath.Join(home, ".claude", "skills"))
	case "codex":
		out = append(out, filepath.Join(home, ".codex", "auth.json"))
	}
	return append(out, filepath.Join(home, ".config", "slipdock"))
}

// DefaultPassEnv is what passes from the daemon's environment when the
// local file names nothing: the agent's own key or token.
func DefaultPassEnv(agent string) []string {
	switch agent {
	case "claude":
		return []string{"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"}
	case "codex":
		return []string{"OPENAI_API_KEY"}
	}
	return nil
}

// cliTarget is where the machine's slipdock CLI is mounted, over the image's.
const cliTarget = "/usr/local/bin/slipdock"

// allowed is the check made before anything runs in a container: the
// runner's image is a name and on the machine's allow-list.
func (c *container) allowed() error {
	return ImageAllowed(c.s.Image, c.s.Images)
}

func (c *container) findRuntime() (string, error) {
	look := c.s.LookPath
	if look == nil {
		look = exec.LookPath
	}
	names := []string{c.s.Runtime}
	if c.s.Runtime == "" {
		names = []string{"docker", "podman"}
	}
	for _, n := range names {
		if filepath.IsAbs(n) {
			if _, err := os.Stat(n); err == nil {
				return n, nil
			}
			continue
		}
		if p, err := look(n); err == nil {
			return p, nil
		}
	}
	return "", fmt.Errorf("container needs Docker or Podman, and %s is not on the daemon's PATH", strings.Join(names, " or "))
}

func (c *container) runtimePath() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.runtime != "" {
		return c.runtime, nil
	}
	p, err := c.findRuntime()
	if err == nil {
		c.runtime = p
	}
	return p, err
}

func (c *container) podman(rt string) bool {
	return strings.Contains(strings.ToLower(filepath.Base(rt)), "podman")
}

// Ready: the image is allowed, Docker or Podman is there, the logins can
// be mounted, and the image is on the machine (unless pulling is allowed).
func (c *container) Ready() error {
	if err := Supported(Container, c.s.GOOS); err != nil {
		return err
	}
	if err := c.allowed(); err != nil {
		return err
	}
	if !oneOf(Pulls, c.s.Pull) {
		return fmt.Errorf("container.pull %q is not one of %s", c.s.Pull, strings.Join(Pulls, ", "))
	}
	for _, name := range c.passEnv() {
		if err := ValidPassEnv(name); err != nil {
			return fmt.Errorf("container.env: %v", err)
		}
	}
	if _, err := c.logins(); err != nil {
		return err
	}
	rt, err := c.runtimePath()
	if err != nil {
		return err
	}
	if c.s.Pull == "never" {
		ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, rt, "image", "inspect", "--format", "{{.Id}}", c.s.Image)
		if out, err := run(ctx, cmd); err != nil {
			return fmt.Errorf("image %s is not on this machine (%s): build or pull it, or set container.pull in the local file",
				c.s.Image, firstLine(out, err))
		}
	}
	return nil
}

func (c *container) passEnv() []string {
	if c.s.PassEnv != nil {
		return c.s.PassEnv
	}
	return DefaultPassEnv(c.s.Agent)
}

// real is path with its links followed, made absolute and clean.
func realPath(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("%q is not an absolute path", path)
	}
	r, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	return filepath.Clean(r), nil
}

// holds: path is dir or inside it.
func holds(dir, path string) bool {
	if dir == path {
		return true
	}
	rel, err := filepath.Rel(dir, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

// mountChars can't be in a path given to --mount, whose value is a
// comma-separated list read as CSV.
func badMountPath(p string) bool {
	return strings.ContainsAny(p, ",\"\n\r\x00") || strings.IndexFunc(p, func(r rune) bool { return r < 0x20 || r == 0x7f }) >= 0
}

func (c *container) realHome() string {
	if c.s.Home == "" {
		return ""
	}
	if h, err := realPath(c.s.Home); err == nil {
		return h
	}
	return filepath.Clean(c.s.Home)
}

// protected is what no mount may be or hold: the daemon's own directory
// (the machine key), the container runtime's sockets and the session's
// runtime directory.
func (c *container) protected() []string {
	list := append([]string{"/var/run/docker.sock", "/run/docker.sock", "/run/podman", "/var/run/podman"}, c.s.Protected...)
	if c.s.Getenv != nil {
		if x := c.s.Getenv("XDG_RUNTIME_DIR"); x != "" {
			list = append(list, x)
		}
	}
	var out []string
	for _, p := range list {
		if !filepath.IsAbs(p) {
			continue
		}
		out = append(out, filepath.Clean(p))
		if r, err := filepath.EvalSymlinks(p); err == nil {
			out = append(out, filepath.Clean(r))
		}
	}
	return out
}

// mountable checks a path to mount: its real path, or why it can't be.
func (c *container) mountable(path string) (string, error) {
	if badMountPath(path) {
		return "", fmt.Errorf("%q can't be mounted: it holds a comma, a quote or a control character", path)
	}
	r, err := realPath(path)
	if err != nil {
		return "", fmt.Errorf("can't mount %s: %v", path, err)
	}
	if badMountPath(r) {
		return "", fmt.Errorf("%q can't be mounted: it holds a comma, a quote or a control character", r)
	}
	if r == "/" || filepath.Dir(r) == r {
		return "", fmt.Errorf("won't mount %s: it is the whole system", r)
	}
	if home := c.realHome(); home != "" && holds(r, home) {
		return "", fmt.Errorf("won't mount %s into a container: it is your home, or holds it", r)
	}
	for _, p := range c.protected() {
		if holds(r, p) || holds(p, r) {
			return "", fmt.Errorf("won't mount %s into a container: it is, holds or is inside %s", r, p)
		}
	}
	return r, nil
}

// logins are the read-only mounts that are there, real paths, each inside
// the home (but not the home itself).
func (c *container) logins() ([]string, error) {
	list := c.s.Login
	if list == nil {
		list = DefaultLogin(c.s.Home, c.s.Agent)
	}
	home := c.realHome()
	var out []string
	for _, l := range list {
		if _, err := os.Lstat(l); err != nil {
			continue
		}
		r, err := c.mountable(l)
		if err != nil {
			return nil, fmt.Errorf("container.login: %v", err)
		}
		if home == "" || r == home || !holds(home, r) {
			return nil, fmt.Errorf("container.login: %s is not inside your home, so it isn't mounted", r)
		}
		out = append(out, r)
	}
	return out, nil
}

// gitTop is the directory at or above dir holding .git (looked for here,
// not by running git, which reads config a job can write), else dir.
func gitTop(dir string) string {
	for d := dir; ; d = filepath.Dir(d) {
		if _, err := os.Lstat(filepath.Join(d, ".git")); err == nil {
			return d
		}
		if filepath.Dir(d) == d {
			return dir
		}
	}
}

// repository is what the daemon's own work for the runner and its hooks
// may write: the runner's repository and its worktrees (<repo>-lanes,
// made here so that it can be mounted).
func (c *container) repository() []string {
	if c.s.Repo == "" {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.top == "" {
		r, err := realPath(c.s.Repo)
		if err != nil {
			return []string{c.s.Repo}
		}
		c.top = gitTop(r)
	}
	lanes := c.top + "-lanes"
	_ = os.MkdirAll(lanes, 0o755)
	return []string{c.top, lanes}
}

// mounts are the read-write mounts for p: its directory's repository (or
// the directory), and what else it may write, none inside another.
func (c *container) mounts(p Proc) ([]string, string, error) {
	dir, err := c.mountable(p.Dir)
	if err != nil {
		return nil, "", err
	}
	paths := []string{gitTop(dir)}
	for _, w := range p.Writable {
		if w != "" {
			paths = append(paths, w)
		}
	}
	var out []string
	for _, path := range paths {
		r, err := c.mountable(path)
		if err != nil {
			return nil, "", err
		}
		out = append(out, r)
	}
	var kept []string
	for i, a := range out {
		inside := false
		for j, b := range out {
			if i != j && holds(b, a) && (a != b || j < i) {
				inside = true
				break
			}
		}
		if !inside {
			kept = append(kept, a)
		}
	}
	return kept, dir, nil
}

// newName is a container's name: slipdock-job-<random>.
var newName = func() string {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("slipdock-job-%d", time.Now().UnixNano())
	}
	return "slipdock-job-" + hex.EncodeToString(b)
}

const namePrefix = "--name="

// Command is prog run in a container: docker or podman run, its options,
// the image, then prog and its arguments, which the runtime passes to the
// container and doesn't read.
func (c *container) Command(p Proc, prog string, args ...string) (*exec.Cmd, error) {
	if err := c.allowed(); err != nil {
		return nil, err
	}
	rt, err := c.runtimePath()
	if err != nil {
		return nil, err
	}
	argv, env, err := c.runArgs(rt, p)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(rt, append(append(argv, c.s.Image, prog), args...)...)
	cmd.Dir = "/"
	cmd.Env = env
	inGroup(cmd)
	return cmd, nil
}

// runArgs are run's options for p (before the image), and the runtime's
// own environment: the variables a --env NAME takes its value from, so no
// value is on a command line.
func (c *container) runArgs(rt string, p Proc) ([]string, []string, error) {
	rw, dir, err := c.mounts(p)
	if err != nil {
		return nil, nil, err
	}
	ro, err := c.logins()
	if err != nil {
		return nil, nil, err
	}
	home := c.realHome()
	if home == "" || badMountPath(home) {
		return nil, nil, fmt.Errorf("container needs the daemon's home, a path it can mount over, not %q", home)
	}
	argv := []string{"run", "--rm", namePrefix + newName(), "--init", "--pull=" + c.s.Pull,
		"--cap-drop=ALL", "--security-opt=no-new-privileges"}
	if c.s.NetworkOff {
		argv = append(argv, "--network=none")
	}
	if c.s.UID >= 0 && c.s.GOOS != "windows" {
		argv = append(argv, fmt.Sprintf("--user=%d:%d", c.s.UID, c.s.GID))
		if c.podman(rt) {
			argv = append(argv, "--userns=keep-id")
		}
	}
	argv = append(argv, "--mount=type=tmpfs,destination="+home+",tmpfs-mode=1777")
	for _, m := range rw {
		argv = append(argv, "--mount=type=bind,source="+m+",destination="+m)
	}
	for _, m := range ro {
		argv = append(argv, "--mount=type=bind,source="+m+",destination="+m+",readonly")
	}
	if p.Transcripts != "" {
		tx, err := c.mountable(p.Transcripts)
		if err != nil {
			return nil, nil, err
		}
		argv = append(argv, "--mount=type=bind,source="+tx+",destination="+TranscriptsAt(home))
	}
	if c.s.CLI != "" {
		if cli, err := realPath(c.s.CLI); err == nil && !badMountPath(cli) {
			argv = append(argv, "--mount=type=bind,source="+cli+",destination="+cliTarget+",readonly")
		}
	}
	argv = append(argv, "--workdir="+dir, "--env=HOME="+home)

	// The runtime's own environment is the daemon's (it may need
	// DOCKER_HOST, say) and the job's; only what --env names gets in.
	env := withoutJobVars(c.environ())
	daemon := map[string]bool{}
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		daemon[name] = true
	}
	env = append(env, p.Env...)
	named := map[string]bool{}
	pass := func(name string) {
		if !named[name] {
			named[name] = true
			argv = append(argv, "--env="+name)
		}
	}
	for _, kv := range p.Env {
		name, _, _ := strings.Cut(kv, "=")
		if envName.MatchString(name) && !reservedEnv[strings.ToUpper(name)] {
			pass(name)
		}
	}
	for _, name := range append(c.passEnv(), "LANG", "LC_ALL", "TZ") {
		if ValidPassEnv(name) == nil && daemon[name] {
			pass(name)
		}
	}
	return argv, env, nil
}

func (c *container) environ() []string {
	if c.s.Environ != nil {
		return c.s.Environ()
	}
	return os.Environ()
}

// Exec runs the daemon's own git or gh in a container, able to write the
// runner's repository and its worktrees.
func (c *container) Exec(ctx context.Context, dir, name string, args ...string) (string, error) {
	cmd, err := c.Command(Proc{Dir: dir, Writable: c.repository()}, name, args...)
	if err != nil {
		return "", err
	}
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		return "", err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err = <-done:
	case <-ctx.Done():
		c.Stop(cmd, true)
		<-done
		err = ctx.Err()
	}
	return out.String(), err
}

// Hook is a runner's hook, in a container that may write the repository
// and its worktrees.
func (c *container) Hook(_ context.Context, p Proc, prog string, args ...string) (*exec.Cmd, error) {
	p.Writable = append(append([]string(nil), p.Writable...), c.repository()...)
	return c.Command(p, prog, args...)
}

// containerName is the --name a command made by Command runs under.
func containerName(args []string) string {
	if len(args) > 3 && args[1] == "run" && strings.HasPrefix(args[3], namePrefix) {
		return strings.TrimPrefix(args[3], namePrefix)
	}
	return ""
}

// Stop stops the container, then the runtime's client: stopping the
// client alone can leave the container running.
func (c *container) Stop(cmd *exec.Cmd, force bool) {
	if cmd.Process == nil {
		return
	}
	if name := containerName(cmd.Args); name != "" && len(cmd.Args) > 0 {
		sig := "TERM"
		if force {
			sig = "KILL"
		}
		ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
		defer cancel()
		_, _ = run(ctx, exec.CommandContext(ctx, cmd.Path, "kill", "--signal="+sig, name))
	}
	signalTree(cmd, force)
}

// Resolve: the program is the image's, found on its PATH when it runs.
func (c *container) Resolve(prog string) (string, error) {
	if strings.TrimSpace(prog) == "" {
		return "", errors.New("no program is named")
	}
	return prog, nil
}

// IsDir: the directories a container sees are mounted from here.
func (c *container) IsDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

// noFiles has nothing in it.
type noFiles struct{}

func (noFiles) ReadFile(path string) ([]byte, error) {
	return nil, fmt.Errorf("%s: not read from a container job", path)
}
func (noFiles) Glob(string, string) []string        { return nil }
func (noFiles) Recent([]string, time.Time) []string { return nil }

func oneOf(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
