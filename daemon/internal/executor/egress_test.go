//go:build !windows

package executor

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/egress"
)

// A job's network allowlist (#3517): the sandboxes let it reach only its
// proxy (and the machine's own ports the allowlist names).

func TestTheSandboxProfileOfAnAllowlistLetsOutOnlyItsPorts(t *testing.T) {
	p := SandboxProfile([]string{"/Users/me/src/repo"}, 4100, 5432)
	for _, want := range []string{"(deny network-outbound)", "(allow network-outbound (remote unix-socket))",
		`(allow network-outbound (remote ip "localhost:4100"))`, `(allow network-outbound (remote ip "localhost:5432"))`} {
		if !strings.Contains(p, want) {
			t.Errorf("profile lacks %s:\n%s", want, p)
		}
	}
	if strings.Index(p, "(deny network-outbound)") > strings.Index(p, "(allow network-outbound") {
		t.Error("the allowances come before the denial, which would win")
	}
	if strings.Contains(SandboxProfile([]string{"/x"}), "network") {
		t.Error("with no allowlist the network is left as it was")
	}
}

func TestAConfinedJobsCommandUnderAnAllowlist(t *testing.T) {
	dir := t.TempDir()
	launcher := filepath.Join(dir, "slipdock-runner")
	_ = os.WriteFile(launcher, []byte("#!/bin/sh\n"), 0o755)
	s := Settings{GOOS: "linux", Launcher: launcher, Egress: &Egress{Port: 4100, Direct: []int{5432}}}
	c := &confined{local: &local{s: s}}
	err := c.Ready()
	switch abi := landlockABI(); {
	case abi >= landlockNetABI && err != nil:
		t.Fatalf("ready: %v", err)
	case abi < landlockNetABI && err == nil:
		t.Fatal("an allowlist is ready on a kernel whose Landlock can't limit TCP")
	case abi >= minLandlockABI && abi < landlockNetABI && !strings.Contains(err.Error(), "Landlock ABI 4"):
		t.Fatalf("says why: %v", err)
	}
	// The command line, as Command builds it, whatever this kernel.
	landlock := landlockABI
	landlockABI = func() int { return landlockNetABI }
	defer func() { landlockABI = landlock }()
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("confined is Linux and macOS only")
	}
	c.s.GOOS = runtime.GOOS
	cmd, err := c.Command(Proc{Dir: dir, Env: []string{"HTTPS_PROXY=http://evil.example.net:1"}}, "/bin/true")
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Join(cmd.Args, " ")
	if runtime.GOOS == "linux" && !strings.Contains(args, " --connect 4100 --connect 5432 -- /bin/true") {
		t.Fatalf("the ports aren't the job's only way out: %s", args)
	}
	if runtime.GOOS == "darwin" && (!strings.Contains(args, "(deny network-outbound)") ||
		!strings.Contains(args, `(remote ip "localhost:4100")`) || !strings.Contains(args, `(remote ip "localhost:5432")`)) {
		t.Fatalf("the ports aren't the job's only way out: %s", args)
	}
	if last := envValue(cmd.Env, "HTTPS_PROXY"); last != "http://127.0.0.1:4100" {
		t.Fatalf("HTTPS_PROXY = %q: the job's own won", last)
	}
	if v := envValue(cmd.Env, "GIT_SSH_COMMAND"); !strings.Contains(v, launcher+" egress connect 127.0.0.1:4100 %h %p") {
		t.Fatalf("GIT_SSH_COMMAND = %q", v)
	}
}

// envValue is the value a process sees: the last one set.
func envValue(env []string, name string) string {
	v := ""
	for _, kv := range env {
		if k, val, ok := strings.Cut(kv, "="); ok && k == name {
			v = val
		}
	}
	return v
}

func TestShellSafe(t *testing.T) {
	for in, want := range map[string]string{"/usr/local/bin/slipdock-runner": "/usr/local/bin/slipdock-runner",
		"/Users/me/My Apps/x": "", `/a"b`: "", "/a$(x)": "", "/a;b": "", "": "", "/opt/v1.2+3/x_y": "/opt/v1.2+3/x_y"} {
		if got := shellSafe(in); got != want {
			t.Errorf("shellSafe(%q) = %q", in, got)
		}
	}
}

// TestAConfinedJobReachesOnlyItsProxy runs a job under the allowlist for
// real: sandbox-exec on macOS, Landlock (ABI 4) on Linux.
func TestAConfinedJobReachesOnlyItsProxy(t *testing.T) {
	if runtime.GOOS == "linux" && landlockABI() < landlockNetABI {
		skipOrFail(t, fmt.Sprintf("this kernel's Landlock is ABI %d, and the allowlist needs %d", landlockABI(), landlockNetABI))
	}
	// Three servers on the machine: one off the allowlist, one the proxy
	// lets through, one the job may reach directly.
	off, allowed, direct := listen(t), listen(t), listen(t)
	p, err := egress.Start([]egress.Rule{{Host: "localhost", Port: port(allowed)}}, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	ex := confinedReady(t)
	c := ex.(*confined)
	c.s.Egress = &Egress{Port: p.Port(), Direct: []int{port(direct)}}
	if err := c.Ready(); err != nil {
		skipOrFail(t, err.Error())
	}
	script := `
try() { l=$1; shift; if "$SELF" "$@" >/dev/null 2>&1; then echo "$l yes"; else echo "$l no"; fi; }
try off helper-dial "127.0.0.1:$OFF"
try direct helper-dial "127.0.0.1:$DIRECT"
try proxy helper-dial "127.0.0.1:$PROXY"
try public helper-dial 1.1.1.1:443
try allowed helper-via "localhost:$ALLOWED"
try offlist helper-via "localhost:$OFF"
echo "proxy=$HTTPS_PROXY"
`
	env := []string{"SELF=" + os.Args[0], "OFF=" + strconv.Itoa(port(off)), "DIRECT=" + strconv.Itoa(port(direct)),
		"PROXY=" + strconv.Itoa(p.Port()), "ALLOWED=" + strconv.Itoa(port(allowed))}
	cmd, err := ex.Command(Proc{Dir: t.TempDir(), Env: env}, "/bin/sh", "-c", script)
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	got := string(out)
	for _, want := range []string{"off no", "direct yes", "proxy yes", "public no", "allowed yes", "offlist no",
		fmt.Sprintf("proxy=http://127.0.0.1:%d", p.Port())} {
		if !strings.Contains(got, want) {
			t.Errorf("want %q; the job said:\n%s", want, got)
		}
	}
}

func listen(t *testing.T) net.Listener {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	return l
}

func port(l net.Listener) int { return l.Addr().(*net.TCPAddr).Port }

func TestAContainerJobUnderAnAllowlistHasOnlyItsProxy(t *testing.T) {
	r := newContainerRig(t)
	sockDir := filepath.Join(r.home, "tmp", "egress")
	_ = os.MkdirAll(sockDir, 0o700)
	launcher := filepath.Join(r.home, "bin", "slipdock-runner")
	_ = os.WriteFile(launcher, []byte("#!/bin/sh\n"), 0o755)
	r.s.Launcher = launcher
	r.s.Egress = &Egress{Port: 4100, Socket: filepath.Join(sockDir, "proxy.sock")}
	cmd, err := r.new(t).Command(Proc{Dir: r.repo, Env: []string{"SLIPDOCK_JOB_ID=9", "HTTPS_PROXY=http://evil.example.net:1"}}, "claude", "-p")
	if err != nil {
		t.Fatal(err)
	}
	opts, rest := split(t, cmd.Args, "ghcr.io/me/agent:1")
	for _, want := range []string{"--network=none",
		"--mount=type=bind,source=" + sockDir + ",destination=/run/slipdock-egress,readonly",
		"--mount=type=bind,source=" + launcher + ",destination=/usr/local/libexec/slipdock-egress,readonly",
		"--env=HTTPS_PROXY", "--env=HTTP_PROXY", "--env=ALL_PROXY", "--env=NO_PROXY", "--env=GIT_SSH_COMMAND"} {
		if !has(opts, want) {
			t.Errorf("no %s in %q", want, opts)
		}
	}
	if got := strings.Join(rest, " "); got != "ghcr.io/me/agent:1 /usr/local/libexec/slipdock-egress egress forward --listen 127.0.0.1:4100 "+
		"--to /run/slipdock-egress/proxy.sock -- claude -p" {
		t.Fatalf("the job doesn't run behind forward: %s", got)
	}
	if v := envValue(cmd.Env, "HTTPS_PROXY"); v != "http://127.0.0.1:4100" {
		t.Fatalf("HTTPS_PROXY = %q: the job's own won", v)
	}
	if v := envValue(cmd.Env, "GIT_SSH_COMMAND"); !strings.Contains(v, "/usr/local/libexec/slipdock-egress egress connect 127.0.0.1:4100 %h %p") {
		t.Fatalf("GIT_SSH_COMMAND = %q", v)
	}
	if containerName(cmd.Args) == "" {
		t.Fatal("the container can't be stopped by name")
	}

	// The daemon's own git runs behind it too.
	r.s.Egress.Socket = ""
	if _, err := r.new(t).Command(Proc{Dir: r.repo}, "git", "fetch"); err == nil || !strings.Contains(err.Error(), "the proxy's socket") {
		t.Fatalf("no socket: %v", err)
	}
	r.s.Egress.Socket = filepath.Join(r.machineDir, "proxy.sock")
	if _, err := r.new(t).Command(Proc{Dir: r.repo}, "git", "fetch"); err == nil {
		t.Fatal("the daemon's own directory was mounted for the socket")
	}
	r.s.Egress.Socket = filepath.Join(sockDir, "proxy.sock")
	r.s.Launcher = ""
	if _, err := r.new(t).Command(Proc{Dir: r.repo}, "git", "fetch"); err == nil {
		t.Fatal("no binary to forward through, and the job ran")
	}
}

func TestAContainerAllowlistIsReadyOnlyOnLinuxWithAStaticBinary(t *testing.T) {
	r := newContainerRig(t)
	launcher := filepath.Join(r.home, "bin", "slipdock-runner")
	_ = os.WriteFile(launcher, []byte("#!/bin/sh\n"), 0o755)
	r.s.Launcher = launcher
	r.s.Egress = &Egress{Port: 4100, Socket: filepath.Join(r.home, "proxy.sock")}
	r.s.GOOS = "darwin"
	if err := r.new(t).Ready(); err == nil || !strings.Contains(err.Error(), "on Linux only, not darwin") {
		t.Fatalf("macOS: %v", err)
	}
	r.s.GOOS = "linux"
	if err := r.new(t).Ready(); err == nil || !strings.Contains(err.Error(), "not a Linux executable") {
		t.Fatalf("a script: %v", err)
	}
	r.s.Launcher = ""
	if err := r.new(t).Ready(); err == nil || !strings.Contains(err.Error(), "can't find its own") {
		t.Fatalf("none: %v", err)
	}
	if runtime.GOOS == "linux" {
		// A Go test binary is dynamically linked when cgo is on; a static one passes.
		r.s.Launcher = staticRunner(t)
		if err := r.new(t).Ready(); err != nil {
			t.Fatalf("a static binary: %v", err)
		}
		if _, err := exec.LookPath("cc"); err == nil {
			if err := staticELF("/bin/sh"); err == nil || !strings.Contains(err.Error(), "linked dynamically") {
				t.Fatalf("/bin/sh: %v", err)
			}
		}
	}
}

// staticRunner builds slipdock-runner as releases do, statically.
func staticRunner(t *testing.T) string {
	t.Helper()
	out := filepath.Join(t.TempDir(), "slipdock-runner")
	cmd := exec.Command("go", "build", "-o", out, "../../cmd/slipdock-runner")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v: %s", err, b)
	}
	return out
}

// TestAContainerJobUnderAnAllowlistRunsInARealContainer: under Docker or
// Podman, where there is one (skipped elsewhere), a job reaches its proxy
// and nothing else.
func TestAContainerJobUnderAnAllowlistRunsInARealContainer(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("the allowlist runs container jobs on Linux")
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
	r.s.Environ = os.Environ
	r.s.Launcher = staticRunner(t)
	allowed := listen(t)
	sockDir, err := os.MkdirTemp("", "slipdock-egress-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(sockDir)
	sock := filepath.Join(sockDir, "proxy.sock")
	p, err := egress.Start([]egress.Rule{{Host: "localhost", Port: port(allowed)}}, sock, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	r.s.Egress = &Egress{Port: p.Port(), Socket: sock}
	ex := r.new(t)
	if err := ex.Ready(); err != nil {
		t.Fatal(err)
	}
	script := `ls /sys/class/net
E=/usr/local/libexec/slipdock-egress
$E egress connect "${HTTPS_PROXY#http://}" localhost ` + strconv.Itoa(port(allowed)) + ` </dev/null && echo "allowed yes" || echo "allowed no"
$E egress connect "${HTTPS_PROXY#http://}" example.com 443 </dev/null 2>&1 | grep -q "refused by the job's network allowlist" && echo "offlist refused"
wget -q -T 5 -O /dev/null http://1.1.1.1/ 2>/dev/null && echo "direct yes" || echo "direct no"
`
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd, err := ex.Command(Proc{Dir: r.repo}, "/bin/sh", "-c", script)
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatal("timed out")
	}
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	got := string(out)
	for _, want := range []string{"allowed yes", "offlist refused", "direct no"} {
		if !strings.Contains(got, want) {
			t.Errorf("want %q; the job said:\n%s", want, got)
		}
	}
	if strings.Contains(got, "eth0") {
		t.Errorf("the container has a network:\n%s", got)
	}
}
