//go:build !windows

package executor

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// containerRig is a home with a repository, a login, the daemon's own
// directory, and a fake runtime that logs what it is asked.
type containerRig struct {
	home, repo, login, machineDir, runtime, calls string
	s                                             Settings
}

func newContainerRig(t *testing.T) *containerRig {
	t.Helper()
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	r := &containerRig{home: home, repo: filepath.Join(home, "src", "repo"),
		login: filepath.Join(home, ".claude", ".credentials.json"), machineDir: filepath.Join(home, ".config", "slipdock-runner", "machine")}
	for _, d := range []string{filepath.Join(r.repo, ".git"), filepath.Join(home, ".claude", "skills"), r.machineDir, filepath.Join(home, "bin")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.WriteFile(r.login, []byte("{}"), 0o600)
	cli := filepath.Join(home, "bin", "slipdock")
	_ = os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o755)
	r.calls = filepath.Join(home, "calls")
	r.runtime = filepath.Join(home, "bin", "docker")
	// The fake runtime: `image inspect` of an image named missing fails.
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + shellQuote(r.calls) + "\n" +
		"case \"$*\" in *'image inspect'*missing*) echo 'No such image' >&2; exit 1;; esac\nexit 0\n"
	if err := os.WriteFile(r.runtime, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	r.s = Settings{GOOS: runtime.GOOS, Home: home, Image: "ghcr.io/me/agent:1", Images: []string{"ghcr.io/me/agent:*"},
		Runtime: r.runtime, Agent: "claude", Protected: []string{r.machineDir}, UID: 1000, GID: 1001, Repo: r.repo, CLI: cli,
		Environ: func() []string {
			return []string{"PATH=/usr/bin:/bin", "SLIPDOCK_TOKEN=sdk_secret", "SLIPDOCK_EXIT=3",
				"CLAUDE_CODE_OAUTH_TOKEN=oauth-secret", "LANG=C.UTF-8", "DOCKER_HOST=unix:///x"}
		},
		Getenv: func(string) string { return "" }}
	return r
}

func (r *containerRig) new(t *testing.T) *container {
	t.Helper()
	ex, err := New(Container, r.s)
	if err != nil {
		t.Fatal(err)
	}
	return ex.(*container)
}

// args is a command's arguments before the image, and from it on.
func split(t *testing.T, args []string, image string) ([]string, []string) {
	t.Helper()
	for i, a := range args {
		if a == image {
			return args[1:i], args[i:]
		}
	}
	t.Fatalf("no image in %q", args)
	return nil, nil
}

func has(list []string, s string) bool { return oneOf(list, s) }

func TestAContainerJobsCommandLine(t *testing.T) {
	r := newContainerRig(t)
	ex := r.new(t)
	cmd, err := ex.Command(Proc{Dir: r.repo, Env: []string{"SLIPDOCK_JOB_ID=9", "SLIPDOCK_PROMPT=Build it"}},
		"claude", "-p", "--privileged", "--volume=/:/host")
	if err != nil {
		t.Fatal(err)
	}
	if cmd.Path != r.runtime {
		t.Fatalf("runs %s", cmd.Path)
	}
	opts, rest := split(t, cmd.Args, "ghcr.io/me/agent:1")
	// The image, then the program and its arguments, which the runtime
	// doesn't read as its own options.
	if strings.Join(rest, " ") != "ghcr.io/me/agent:1 claude -p --privileged --volume=/:/host" {
		t.Fatalf("after the options: %q", rest)
	}
	if opts[0] != "run" || opts[1] != "--rm" || !strings.HasPrefix(opts[2], "--name=slipdock-job-") {
		t.Fatalf("starts %q", opts[:3])
	}
	for _, want := range []string{
		"--init", "--pull=never", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--user=1000:1001",
		"--mount=type=tmpfs,destination=" + r.home + ",tmpfs-mode=1777",
		"--mount=type=bind,source=" + r.repo + ",destination=" + r.repo,
		"--mount=type=bind,source=" + r.login + ",destination=" + r.login + ",readonly",
		"--mount=type=bind,source=" + filepath.Join(r.home, ".claude", "skills") + ",destination=" + filepath.Join(r.home, ".claude", "skills") + ",readonly",
		"--mount=type=bind,source=" + r.s.CLI + ",destination=/usr/local/bin/slipdock,readonly",
		"--workdir=" + r.repo, "--env=HOME=" + r.home,
		"--env=SLIPDOCK_JOB_ID", "--env=SLIPDOCK_PROMPT", "--env=CLAUDE_CODE_OAUTH_TOKEN", "--env=LANG",
	} {
		if !has(opts, want) {
			t.Errorf("no %s in %q", want, opts)
		}
	}
	if has(opts, "--network=none") {
		t.Error("the network is off only when the runner asks")
	}
	// Only the repository is mounted read-write; everything else is read-only.
	for _, o := range opts {
		if strings.HasPrefix(o, "--mount=type=bind,") && !strings.HasSuffix(o, ",readonly") && o != "--mount=type=bind,source="+r.repo+",destination="+r.repo {
			t.Errorf("mounted read-write: %s", o)
		}
		for _, bad := range []string{"SLIPDOCK_TOKEN", "SLIPDOCK_EXIT", "DOCKER_HOST", "secret", "Build it", "--privileged", "/:/host"} {
			if strings.Contains(o, bad) {
				t.Errorf("an option carries %s: %s", bad, o)
			}
		}
	}
	// The values are in the runtime's environment, never on its command line.
	env := "\n" + strings.Join(cmd.Env, "\n") + "\n"
	for _, want := range []string{"\nSLIPDOCK_JOB_ID=9\n", "\nSLIPDOCK_PROMPT=Build it\n", "\nCLAUDE_CODE_OAUTH_TOKEN=oauth-secret\n", "\nDOCKER_HOST=unix:///x\n"} {
		if !strings.Contains(env, want) {
			t.Errorf("the runtime's environment lacks %q", want)
		}
	}
	if strings.Contains(env, "SLIPDOCK_EXIT") {
		t.Error("the daemon's own job variables passed on")
	}
	if cmd.SysProcAttr == nil {
		t.Error("the runtime's client starts in a process group of its own")
	}
	if containerName(cmd.Args) != strings.TrimPrefix(opts[2], "--name=") {
		t.Errorf("containerName = %q", containerName(cmd.Args))
	}
}

func TestAContainerCanHaveItsNetworkOffAndRunUnderPodman(t *testing.T) {
	r := newContainerRig(t)
	r.s.NetworkOff = true
	podman := filepath.Join(r.home, "bin", "podman")
	if err := os.Link(r.runtime, podman); err != nil {
		t.Fatal(err)
	}
	r.s.Runtime = podman
	r.s.Pull = "missing"
	r.s.Login = []string{} // none
	r.s.PassEnv = []string{"GOFLAGS"}
	cmd, err := r.new(t).Command(Proc{Dir: r.repo}, "sh")
	if err != nil {
		t.Fatal(err)
	}
	opts, _ := split(t, cmd.Args, "ghcr.io/me/agent:1")
	for _, want := range []string{"--network=none", "--userns=keep-id", "--pull=missing"} {
		if !has(opts, want) {
			t.Errorf("no %s in %q", want, opts)
		}
	}
	for _, o := range opts {
		if strings.Contains(o, ".credentials.json") || strings.Contains(o, "CLAUDE_CODE_OAUTH_TOKEN") {
			t.Errorf("an empty login list mounts nothing, and env passes only what it names: %s", o)
		}
	}
}

func TestAContainerJobInAWorktreeMountsItAndItsRepository(t *testing.T) {
	r := newContainerRig(t)
	lane := filepath.Join(r.repo+"-lanes", "card-7")
	if err := os.MkdirAll(lane, 0o755); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(lane, ".git"), []byte("gitdir: "+r.repo+"/.git/worktrees/card-7\n"), 0o644)
	ex := r.new(t)
	cmd, err := ex.Command(Proc{Dir: lane, Writable: []string{r.repo}}, "claude")
	if err != nil {
		t.Fatal(err)
	}
	opts, _ := split(t, cmd.Args, "ghcr.io/me/agent:1")
	var rw []string
	for _, o := range opts {
		if strings.HasPrefix(o, "--mount=type=bind,") && !strings.HasSuffix(o, ",readonly") {
			rw = append(rw, o)
		}
	}
	want := []string{"--mount=type=bind,source=" + lane + ",destination=" + lane,
		"--mount=type=bind,source=" + r.repo + ",destination=" + r.repo}
	if strings.Join(rw, " ") != strings.Join(want, " ") {
		t.Fatalf("read-write mounts %q, want %q (the job's worktree and its repository, not the other worktrees)", rw, want)
	}

	// Its hooks and the daemon's own git may write the worktrees too.
	hook, err := ex.Hook(context.Background(), Proc{Dir: lane, Writable: []string{r.repo}}, "/usr/local/bin/fresh")
	if err != nil {
		t.Fatal(err)
	}
	if !has(hook.Args, "--mount=type=bind,source="+r.repo+"-lanes,destination="+r.repo+"-lanes") {
		t.Errorf("the hook can't write the worktrees: %q", hook.Args)
	}
}

func TestAContainerRefusesToMountTheHomeOrTheDaemonsOwnFiles(t *testing.T) {
	r := newContainerRig(t)
	link := filepath.Join(r.home, "src", "looks-fine")
	if err := os.Symlink(r.home, link); err != nil {
		t.Fatal(err)
	}
	comma := filepath.Join(r.home, "src", "a,readonly=false")
	_ = os.MkdirAll(comma, 0o755)
	inMachine := filepath.Join(r.machineDir, "jobs")
	_ = os.MkdirAll(inMachine, 0o755)
	dotfiles := filepath.Join(r.home, "notes")
	_ = os.MkdirAll(dotfiles, 0o755)
	for _, c := range []struct {
		name string
		p    Proc
		want string
	}{
		{"the home", Proc{Dir: r.home}, "it is your home, or holds it"},
		{"what holds the home", Proc{Dir: filepath.Dir(r.home)}, "it is your home, or holds it"},
		{"the whole system", Proc{Dir: "/"}, "the whole system"},
		{"a link to the home", Proc{Dir: link}, "it is your home, or holds it"},
		{"the daemon's directory's parent", Proc{Dir: filepath.Join(r.home, ".config")}, "is, holds or is inside " + r.machineDir},
		{"inside the daemon's directory", Proc{Dir: inMachine}, "is, holds or is inside " + r.machineDir},
		{"a path with a comma", Proc{Dir: comma}, "a comma"},
		{"a writable path that is the home", Proc{Dir: r.repo, Writable: []string{r.home}}, "your home"},
		{"not there", Proc{Dir: filepath.Join(r.home, "gone")}, "can't mount"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if _, err := r.new(t).Command(c.p, "sh"); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
	// A directory under a home that is a git repository (dotfiles) is
	// mounted with its repository, the home: refused.
	if err := os.MkdirAll(filepath.Join(r.home, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := r.new(t).Command(Proc{Dir: dotfiles}, "sh"); err == nil || !strings.Contains(err.Error(), "your home") {
		t.Fatalf("a directory whose repository is the home: %v", err)
	}
}

func TestAContainerMountsLoginsFromTheHomeOnly(t *testing.T) {
	outside, _ := filepath.EvalSymlinks(t.TempDir())
	secret := filepath.Join(outside, "id_ed25519")
	_ = os.WriteFile(secret, []byte("key"), 0o600)
	for _, c := range []struct {
		name  string
		login func(r *containerRig) []string
		want  string
	}{
		{"outside the home", func(r *containerRig) []string { return []string{secret} }, "is not inside your home"},
		{"the home itself", func(r *containerRig) []string { return []string{r.home} }, "your home"},
		{"a link out of the home", func(r *containerRig) []string {
			l := filepath.Join(r.home, ".claude", "link")
			_ = os.Symlink(secret, l)
			return []string{l}
		}, "is not inside your home"},
		{"the daemon's directory", func(r *containerRig) []string { return []string{r.machineDir} }, "is, holds or is inside"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := newContainerRig(t)
			r.s.Login = c.login(r)
			ex := r.new(t)
			if _, err := ex.Command(Proc{Dir: r.repo}, "sh"); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("Command: %v, want %q", err, c.want)
			}
			if err := ex.Ready(); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("Ready: %v, want %q", err, c.want)
			}
		})
	}
	// One that isn't there is left out.
	r := newContainerRig(t)
	r.s.Login = []string{filepath.Join(r.home, ".codex", "auth.json")}
	if cmd, err := r.new(t).Command(Proc{Dir: r.repo}, "sh"); err != nil || strings.Contains(strings.Join(cmd.Args, " "), "auth.json") {
		t.Fatalf("a login that isn't there: %v", err)
	}
}

func TestAContainerRunsOnlyAnAllowedImage(t *testing.T) {
	r := newContainerRig(t)
	r.s.Image = "docker.io/someone/agent:1"
	if _, err := New(Container, r.s); err == nil || !strings.Contains(err.Error(), "not on this machine's allow-list") {
		t.Fatalf("New: %v", err)
	}
	r.s.Images = nil
	if _, err := New(Container, r.s); err == nil || !strings.Contains(err.Error(), "allows no images") {
		t.Fatalf("New with no list: %v", err)
	}
	// Each process checks again, so an executor holding an image that
	// isn't allowed starts nothing.
	c := newContainer(r.s)
	if _, err := c.Command(Proc{Dir: r.repo}, "sh"); err == nil || !strings.Contains(err.Error(), "allows no images") {
		t.Fatalf("Command: %v", err)
	}
	if _, err := c.Exec(context.Background(), r.repo, "git", "status"); err == nil {
		t.Fatal("Exec ran under an image that isn't allowed")
	}
	if err := c.Ready(); err == nil || !strings.Contains(err.Error(), "allows no images") {
		t.Fatalf("Ready: %v", err)
	}
	if b, _ := os.ReadFile(r.calls); len(b) != 0 {
		t.Fatalf("the runtime was run: %s", b)
	}
}

func TestContainerReady(t *testing.T) {
	r := newContainerRig(t)
	if err := r.new(t).Ready(); err != nil {
		t.Fatalf("ready: %v", err)
	}
	if b, _ := os.ReadFile(r.calls); !strings.Contains(string(b), "image inspect --format {{.Id}} ghcr.io/me/agent:1") {
		t.Fatalf("the image wasn't looked for: %s", b)
	}

	r.s.Image = "ghcr.io/me/agent:missing"
	if err := r.new(t).Ready(); err == nil || !strings.Contains(err.Error(), "is not on this machine (No such image)") {
		t.Fatalf("an image that isn't here: %v", err)
	}
	r.s.Pull = "missing"
	if err := r.new(t).Ready(); err != nil {
		t.Fatalf("with pull missing the runtime fetches it: %v", err)
	}
	r.s.Pull = "sometimes"
	if err := r.new(t).Ready(); err == nil || !strings.Contains(err.Error(), "container.pull") {
		t.Fatalf("a pull policy that isn't one: %v", err)
	}
	r.s.Pull = ""
	r.s.PassEnv = []string{"SLIPDOCK_TOKEN"}
	if err := r.new(t).Ready(); err == nil || !strings.Contains(err.Error(), "never pass") {
		t.Fatalf("a SLIPDOCK_ variable to pass: %v", err)
	}
	r.s.PassEnv = nil
	r.s.Runtime = filepath.Join(r.home, "no-such-runtime")
	if err := r.new(t).Ready(); err == nil || !strings.Contains(err.Error(), "needs Docker or Podman") {
		t.Fatalf("no runtime: %v", err)
	}
	r.s.Runtime = ""
	r.s.LookPath = func(string) (string, error) { return "", exec.ErrNotFound }
	if err := r.new(t).Ready(); err == nil || !strings.Contains(err.Error(), "docker or podman is not on the daemon's PATH") {
		t.Fatalf("no runtime on the PATH: %v", err)
	}
}

func TestStoppingAContainerJobStopsTheContainer(t *testing.T) {
	r := newContainerRig(t)
	ex := r.new(t)
	cmd, err := ex.Command(Proc{Dir: r.repo}, "sleep", "60")
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()
	name := containerName(cmd.Args)
	ex.Stop(cmd, false)
	ex.Stop(cmd, true)
	b, _ := os.ReadFile(r.calls)
	for _, want := range []string{"kill --signal=TERM " + name, "kill --signal=KILL " + name} {
		if !strings.Contains(string(b), want) {
			t.Errorf("no %q in the runtime's calls:\n%s", want, b)
		}
	}
	if containerName([]string{"docker", "run", "--rm", "claude", "--name=x"}) != "" {
		t.Error("a --name after the options is the program's")
	}
}

func TestAContainerJobsFilesAreNotRead(t *testing.T) {
	r := newContainerRig(t)
	ex := r.new(t)
	f := ex.Files()
	if _, err := f.ReadFile(r.login); err == nil {
		t.Error("read a file for a container job")
	}
	if f.Glob(r.home, "*") != nil || f.Recent([]string{r.login}, time.Time{}) != nil {
		t.Error("listed files for a container job")
	}
	if p, err := ex.Resolve("claude"); err != nil || p != "claude" {
		t.Errorf("Resolve = %q, %v: the image's PATH finds it", p, err)
	}
	if _, err := ex.Resolve(" "); err == nil {
		t.Error("an empty program resolves")
	}
	if !ex.IsDir(r.repo) || ex.IsDir(filepath.Join(r.repo, "gone")) {
		t.Error("IsDir")
	}
}

// TestAContainerJobRunsInARealContainer runs a job's processes under Docker
// or Podman, where there is one (skipped elsewhere).
func TestAContainerJobRunsInARealContainer(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("the real-runtime test runs on Linux")
	}
	rt := ""
	for _, n := range []string{"docker", "podman"} {
		if p, err := exec.LookPath(n); err == nil && exec.Command(p, "info").Run() == nil {
			rt = p
			break
		}
	}
	if rt == "" {
		t.Skip("no Docker or Podman that runs here")
	}
	image := os.Getenv("SLIPDOCK_CONTAINER_TEST_IMAGE")
	if image == "" {
		image = "alpine:3"
	}
	r := newContainerRig(t)
	r.s.Runtime, r.s.Image, r.s.Images, r.s.Pull = rt, image, []string{image}, "missing"
	r.s.UID, r.s.GID = os.Getuid(), os.Getgid()
	r.s.Environ = func() []string { return append(os.Environ(), "SLIPDOCK_TOKEN=sdk_secret") }
	outside := filepath.Join(r.home, "outside.txt")
	_ = os.WriteFile(outside, []byte("private"), 0o644)
	_ = os.WriteFile(r.login, []byte("login\n"), 0o644)

	runIn := func(off bool, script string) (string, error) {
		r.s.NetworkOff = off
		ex := r.new(t)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		cmd, err := ex.Command(Proc{Dir: r.repo, Env: []string{"SLIPDOCK_JOB_ID=4"}}, "/bin/sh", "-c", script)
		if err != nil {
			return "", err
		}
		out, err := cmd.CombinedOutput()
		if ctx.Err() != nil {
			t.Fatal("timed out")
		}
		return string(out), err
	}
	script := `echo made > made.txt
pwd; id -u; echo "job=$SLIPDOCK_JOB_ID token=${SLIPDOCK_TOKEN:-none} home=$HOME"
cat ` + shellQuote(outside) + ` 2>/dev/null || echo "no outside"
echo x >> ` + shellQuote(r.login) + ` 2>/dev/null && echo "login written" || echo "login read-only"
cat ` + shellQuote(r.login) + `
echo y > "$HOME/left.txt" && echo "home written"
ls /sys/class/net`
	out, err := runIn(true, script)
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	for _, want := range []string{r.repo + "\n", "job=4 token=none home=" + r.home, "no outside", "login read-only", "login\n", "home written"} {
		if !strings.Contains(out, want) {
			t.Errorf("no %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "eth0") || !strings.Contains(out, "lo") {
		t.Errorf("the network was on:\n%s", out)
	}
	if b, err := os.ReadFile(filepath.Join(r.repo, "made.txt")); err != nil || string(b) != "made\n" {
		t.Errorf("the job's write to its directory isn't there: %q %v", b, err)
	}
	if fi, err := os.Stat(filepath.Join(r.repo, "made.txt")); err == nil {
		if st, ok := fi.Sys().(interface{ Uid() uint32 }); ok && int(st.Uid()) != os.Getuid() {
			t.Error("the job's file isn't the daemon's account's")
		}
	}
	if _, err := os.Stat(filepath.Join(r.home, "left.txt")); err == nil {
		t.Error("a write to the container's home reached the real one")
	}
	if b, _ := os.ReadFile(r.login); string(b) != "login\n" {
		t.Errorf("the login changed: %q", b)
	}

	out, err = runIn(false, "ls /sys/class/net")
	if err != nil || !strings.Contains(out, "eth0") {
		t.Logf("with the network on: %q %v", out, err)
	}
}
