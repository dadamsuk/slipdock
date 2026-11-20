//go:build !windows

package executor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// tripwireRig is a container rig under an allowlist, with a directory of
// fake credentials laid out as a home (#3524).
func tripwireRig(t *testing.T) (*containerRig, string) {
	t.Helper()
	r := newContainerRig(t)
	sockDir := filepath.Join(r.home, "tmp", "egress")
	_ = os.MkdirAll(sockDir, 0o700)
	launcher := filepath.Join(r.home, "bin", "slipdock-runner")
	_ = os.WriteFile(launcher, []byte("#!/bin/sh\n"), 0o755)
	tw, _ := filepath.EvalSymlinks(t.TempDir())
	for _, d := range TripwireDirs {
		_ = os.MkdirAll(filepath.Join(tw, d), 0o700)
	}
	r.s.Launcher = launcher
	r.s.Egress = &Egress{Port: 4100, Socket: filepath.Join(sockDir, "proxy.sock"), Tripwire: tw}
	return r, tw
}

func tripwireMountsOf(t *testing.T, r *containerRig) []string {
	t.Helper()
	cmd, err := r.new(t).Command(Proc{Dir: r.repo}, "claude", "-p")
	if err != nil {
		t.Fatal(err)
	}
	opts, _ := split(t, cmd.Args, "ghcr.io/me/agent:1")
	var out []string
	for _, o := range opts {
		if r.s.Egress.Tripwire != "" && strings.Contains(o, "source="+r.s.Egress.Tripwire+"/") {
			out = append(out, o)
		}
	}
	return out
}

func TestAContainerJobsHomeHasItsFakeCredentials(t *testing.T) {
	r, tw := tripwireRig(t)
	got := tripwireMountsOf(t, r)
	want := []string{
		"--mount=type=bind,source=" + filepath.Join(tw, ".aws") + ",destination=" + filepath.Join(r.home, ".aws") + ",readonly",
		"--mount=type=bind,source=" + filepath.Join(tw, ".config", "gh") + ",destination=" + filepath.Join(r.home, ".config", "gh") + ",readonly",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("mounts:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	// Without an allowlist's tripwire, none.
	r.s.Egress.Tripwire = ""
	cmd, err := r.new(t).Command(Proc{Dir: r.repo}, "claude", "-p")
	if err != nil {
		t.Fatal(err)
	}
	if args := strings.Join(cmd.Args, " "); strings.Contains(args, "/.aws,") || strings.Contains(args, "/gh,") {
		t.Fatalf("no tripwire, but %s", args)
	}
}

func TestAFakeCredentialNeverCoversALoginOfTheMachines(t *testing.T) {
	r, tw := tripwireRig(t)
	aws := filepath.Join(r.home, ".aws", "credentials")
	_ = os.MkdirAll(filepath.Dir(aws), 0o700)
	_ = os.WriteFile(aws, []byte("real"), 0o600)
	gh := filepath.Join(r.home, ".config", "gh")
	_ = os.MkdirAll(gh, 0o700)
	r.s.Login = []string{r.login, aws}
	got := strings.Join(tripwireMountsOf(t, r), "\n")
	if strings.Contains(got, "/.aws,") || !strings.Contains(got, filepath.Join(tw, ".config", "gh")) {
		t.Fatalf("the machine's ~/.aws/credentials is mounted, yet: %s", got)
	}
	r.s.Login = []string{r.login, gh}
	got = strings.Join(tripwireMountsOf(t, r), "\n")
	if strings.Contains(got, "/gh,") || !strings.Contains(got, filepath.Join(tw, ".aws")) {
		t.Fatalf("the machine's ~/.config/gh is mounted, yet: %s", got)
	}
	hosts := filepath.Join(gh, "hosts.yml")
	_ = os.WriteFile(hosts, []byte("real"), 0o600)
	r.s.Login = []string{r.login, hosts}
	if got := tripwireMountsOf(t, r); len(got) != 1 || !strings.Contains(got[0], "/.aws,") {
		t.Fatalf("a login inside ~/.config/gh: %q", got)
	}
}

func TestATripwireInTheDaemonsOwnDirectoryIsRefused(t *testing.T) {
	r, _ := tripwireRig(t)
	tw := filepath.Join(r.machineDir, "tw")
	_ = os.MkdirAll(filepath.Join(tw, ".aws"), 0o700)
	r.s.Egress.Tripwire = tw
	if _, err := r.new(t).Command(Proc{Dir: r.repo}, "claude"); err == nil || !strings.Contains(err.Error(), "the job's tripwire") {
		t.Fatalf("mounted from the daemon's own directory: %v", err)
	}
}
