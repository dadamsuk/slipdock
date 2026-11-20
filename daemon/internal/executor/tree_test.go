package executor

import (
	"os/exec"
	"strings"
	"testing"
)

func TestStrays(t *testing.T) {
	const wt = "/w/lanes/card-1"
	procs := []liveProc{
		{pid: 1, tagged: true},                        // init: never
		{pid: 50, tagged: true},                       // the daemon itself: never
		{pid: 100, tagged: true},                      // left the group, kept the tag
		{pid: 101, cwd: wt},                           // no tag, working in the worktree
		{pid: 102, cwd: wt + "/lib"},                  // beneath it
		{pid: 103, cwd: wt, tty: true},                // a person's shell there
		{pid: 104, cwd: wt + "-other"},                // a neighbour whose name starts the same
		{pid: 105, cwd: "/elsewhere"},                 // someone else's
		{pid: 106, tagged: true, tty: true, cwd: "/"}, // tagged at a terminal: still the job's
	}
	if got, want := strays(procs, wt, 50), []int{100, 101, 102, 106}; !sameInts(got, want) {
		t.Fatalf("in a worktree: got %v, want %v", got, want)
	}
	if got, want := strays(procs, "", 50), []int{100, 106}; !sameInts(got, want) {
		t.Fatalf("by the tag alone: got %v, want %v", got, want)
	}
	if got := strays(procs, wt+"/", 50); !sameInts(got, []int{100, 101, 102, 106}) {
		t.Fatalf("a worktree with a trailing slash: %v", got)
	}
	if got := strays(procs, "/", 50); !sameInts(got, []int{100, 106}) {
		t.Fatalf("the root is no worktree: %v", got)
	}
}

func TestPsProcsAndLsofCwds(t *testing.T) {
	tag := "SLIPDOCK_TREE=abc"
	ps := `  100 ??       /usr/local/bin/node server.js PATH=/usr/bin SLIPDOCK_TREE=abc HOME=/h
  101 ttys001  /bin/zsh -l
  102 ??       /bin/sleep 300
  103 ??       grep SLIPDOCK_TREE=abcd
  104 ??       echo xSLIPDOCK_TREE=abc
garbage line
`
	got := psProcs(ps, tag)
	want := []liveProc{{pid: 100, tagged: true}, {pid: 101, tty: true}, {pid: 102}, {pid: 103}, {pid: 104}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("%d: got %+v, want %+v", i, got[i], want[i])
		}
	}
	if procs := psProcs(ps, ""); procs[0].tagged {
		t.Fatal("no tag tags nothing")
	}
	cwds := lsofCwds("p102\nfcwd\nn/w/lanes/card-1\np105\nfcwd\nn/tmp/a b\n")
	if cwds[102] != "/w/lanes/card-1" || cwds[105] != "/tmp/a b" || len(cwds) != 2 {
		t.Fatalf("lsofCwds: %v", cwds)
	}
}

func TestEnvironPids(t *testing.T) {
	got := environPids("/proc/12/environ\n/proc/self/environ\nsudo: oops\n/proc/345/environ\n")
	if !sameInts(got, []int{12, 345}) {
		t.Fatalf("got %v", got)
	}
}

func TestEachCommandIsTaggedAfresh(t *testing.T) {
	ex, err := New(Me, Settings{GOOS: "linux", Environ: func() []string { return []string{"SLIPDOCK_TREE=the-daemons", "HOME=/h"} }})
	if err != nil {
		t.Fatal(err)
	}
	a, _ := ex.Command(Proc{Dir: "/w", Env: []string{"SLIPDOCK_TREE=the-jobs"}}, "true")
	b, _ := ex.Command(Proc{Dir: "/w"}, "true")
	ta, tb := treeTag(a), treeTag(b)
	if !strings.HasPrefix(ta, "SLIPDOCK_TREE=") || len(ta) < len("SLIPDOCK_TREE=")+32 || ta == tb {
		t.Fatalf("tags %q and %q", ta, tb)
	}
	if a.Env[len(a.Env)-1] != ta || strings.Contains(strings.Join(a.Env, "\n"), "the-daemons") {
		t.Fatalf("the command's own tag goes last, the daemon's not at all: %v", a.Env)
	}
	if treeTag(exec.Command("true")) != "" {
		t.Fatal("an untagged command has no tag")
	}

	acct := newAccount(Settings{GOOS: "linux", Account: "sdjobs", AccountHome: "/home/sdjobs"})
	c, _ := acct.Command(Proc{Dir: "/w", Env: []string{"SLIPDOCK_TREE=the-jobs"}}, "/bin/sh", "-c", "echo SLIPDOCK_TREE=fake")
	tc := accountTag(c.Args)
	if !strings.HasPrefix(tc, "SLIPDOCK_TREE=") || tc == "SLIPDOCK_TREE=the-jobs" || tc == "SLIPDOCK_TREE=fake" {
		t.Fatalf("the account's tag: %q in %v", tc, c.Args)
	}
	if accountTag([]string{"sudo", "SLIPDOCK_TREE=x"}) != "" {
		t.Fatal("no shell, no tag")
	}
}

func TestUnion(t *testing.T) {
	if got := union([]int{5, 3, 1}, []int{3, 7, 0}); !sameInts(got, []int{3, 5, 7}) {
		t.Fatalf("got %v", got)
	}
}
