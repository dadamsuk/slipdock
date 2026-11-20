package runner

import (
	"net/http"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// The trust tier a job carries (#3516), and what the ceiling's tiers make
// of it.

func TestTheTierIsReadFromTheClaim(t *testing.T) {
	for header, want := range map[string]string{
		"owner": "owner", "member": "member", "anyone": "anyone", "": "", "root": "anyone",
	} {
		h := http.Header{}
		h.Set("X-Job-Id", "5")
		if header != "" {
			h.Set("X-Prompt-Tier", header)
		}
		job, err := parseJob(h, nil)
		if err != nil || job.Tier != want {
			t.Errorf("X-Prompt-Tier %q: tier %q, err %v; want %q", header, job.Tier, err, want)
		}
	}
}

func TestNoTiersRunsTheJobAsTheRunnerSays(t *testing.T) {
	w := &Worker{Logf: func(string, ...any) {}, Runner: Runner{Config: Config{PermissionMode: "bypassPermissions"}}}
	got, err := w.forTier(&Job{Tier: "anyone"})
	if err != nil || got != w {
		t.Fatalf("forTier = %v, %v; want the worker itself", got, err)
	}
}

func TestATiersLimitsApplyToTheJob(t *testing.T) {
	tiers := map[string]machine.Tier{
		"owner":  {MaxPermissionMode: "acceptEdits"},
		"member": {MaxPermissionMode: "plan"},
		"anyone": {Executor: executor.Container, Network: "off", MaxPermissionMode: "plan"},
	}
	w := &Worker{Logf: func(string, ...any) {}, Runner: Runner{Config: Config{PermissionMode: "acceptEdits", Image: "img"}}, Tiers: tiers,
		Images: []string{"img"}}

	owner, err := w.forTier(&Job{Tier: "owner"})
	if err != nil || owner != w {
		t.Fatalf("owner: %v, %v; want the worker itself (inside its limits)", owner, err)
	}

	member, err := w.forTier(&Job{Tier: "member"})
	if err != nil || member.Runner.Config.PermissionMode != "plan" || member.Executor != w.Executor {
		t.Fatalf("member: %+v, %v; want plan, the same executor", member, err)
	}
	if w.Runner.Config.PermissionMode != "acceptEdits" {
		t.Fatal("the tier changed the runner's own config")
	}

	for _, tier := range []string{"anyone", ""} {
		got, err := w.forTier(&Job{Tier: tier})
		if err != nil {
			t.Fatalf("%q: %v", tier, err)
		}
		c := got.Runner.Config
		if c.Executor != executor.Container || c.Network != "off" || c.PermissionMode != "plan" {
			t.Fatalf("%q: config %+v; want container, network off, plan", tier, c)
		}
		if !got.executorSettings().NetworkOff {
			t.Fatalf("%q: the container's network is on", tier)
		}
		if got.Executor == nil || got.Executor.Name() != executor.Container {
			t.Fatalf("%q: the job's executor is %v, %v; want the container", tier, got.Executor, got.executorErr)
		}
	}
}

func TestATierNeverRaisesTheRunnersMode(t *testing.T) {
	w := &Worker{Logf: func(string, ...any) {}, Runner: Runner{Config: Config{PermissionMode: "plan"}},
		Tiers: map[string]machine.Tier{"owner": {MaxPermissionMode: "bypassPermissions"}}}
	got, err := w.forTier(&Job{Tier: "owner"})
	if err != nil || got.Runner.Config.PermissionMode != "plan" {
		t.Fatalf("forTier = %+v, %v; want plan", got, err)
	}
}

func TestATierWithNoEntryOrNoContainerIsRefused(t *testing.T) {
	w := &Worker{Logf: func(string, ...any) {}, Runner: Runner{Config: Config{}},
		Tiers: map[string]machine.Tier{"owner": {}, "member": {Network: "off"}}}
	if _, err := w.forTier(&Job{Tier: "anyone"}); err == nil || !strings.Contains(err.Error(), `trust tier "anyone"`) {
		t.Fatalf("anyone: %v", err)
	}
	if _, err := w.forTier(&Job{}); err == nil || !strings.Contains(err.Error(), `trust tier "anyone"`) {
		t.Fatalf("no tier: %v; want it read as anyone", err)
	}
	if _, err := w.forTier(&Job{Tier: "member"}); err == nil || !strings.Contains(err.Error(), "needs the container executor") {
		t.Fatalf("member: %v", err)
	}
}

func TestAJobWhoseTierHasNoEntryIsNotRun(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Tiers = map[string]machine.Tier{"owner": {}}
	f := r.runJob(fakeJob{id: 120, kind: "claude", card: 7, tier: "member", prompt: "x"})
	if f.exit != 127 || f.status != "failed" || !strings.Contains(f.body, `trust tier "member"`) {
		t.Fatalf("finish = %+v", f)
	}
	if r.agentSaw() != "" {
		t.Fatal("the agent ran for a tier the ceiling doesn't name")
	}
}

func TestAJobRunsWithItsTiersMode(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Tiers = map[string]machine.Tier{"member": {MaxPermissionMode: "plan"}}
	f := r.runJob(fakeJob{id: 121, kind: "claude", card: 7, tier: "member", prompt: "x"})
	if f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if saw := r.agentSaw(); !strings.Contains(saw, "arg=--permission-mode\narg=plan\n") {
		t.Fatalf("the agent wasn't run in plan mode:\n%s", saw)
	}
}
