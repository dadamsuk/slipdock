package runner

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// #2920: an agent that can't run is the machine's trouble, not the card's.

func TestTheLimitMessageAndItsReset(t *testing.T) {
	now := time.Date(2026, 11, 12, 22, 32, 0, 0, time.UTC)
	cases := []struct {
		name, log string
		found     bool
		want      time.Time
	}{
		{"the weekly limit, with a date", "starting\nYou've hit your weekly limit · resets Nov 15, 6pm\n", true,
			time.Date(2026, 11, 15, 18, 0, 0, 0, time.UTC)},
		{"a time later today", "Claude usage limit reached. resets 11:30pm", true,
			time.Date(2026, 11, 12, 23, 30, 0, 0, time.UTC)},
		{"a time already past today is tomorrow's", "You've hit your session limit · resets 3am", true,
			time.Date(2026, 11, 13, 3, 0, 0, 0, time.UTC)},
		{"12am is midnight", "You've hit your limit · resets 12am", true,
			time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC)},
		{"12pm is noon", "You've hit your limit · resets Nov 13, 12pm", true,
			time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)},
		{"a stated zone", "You've hit your limit · resets 6pm (Europe/Paris)", true,
			time.Date(2026, 11, 13, 17, 0, 0, 0, time.UTC)},
		{"a date already past is next year's, and too far to believe", "You've hit your weekly limit · resets Jan 1, 6pm", true,
			time.Time{}},
		{"no reset stated", "You've hit your weekly limit", true, time.Time{}},
		{"an unknown zone", "You've hit your limit · resets 6pm (Nowhere/Atlantis)", true, time.Time{}},
		{"no hour 25", "You've hit your limit · resets 25:00", true, time.Time{}},
		{"an ordinary failure", "error: tests failed\nexit 1\n", false, time.Time{}},
		{"the word limit alone is not it", "the page's size limit is 64 KB", false, time.Time{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			found, line, at := limitIn([]byte(c.log), now)
			if found != c.found {
				t.Fatalf("found = %v, want %v (line %q)", found, c.found, line)
			}
			if !at.Equal(c.want) {
				t.Fatalf("reset = %v, want %v", at, c.want)
			}
			if found && strings.Contains(line, "\n") {
				t.Fatalf("line = %q: one line", line)
			}
		})
	}
}

func TestTheLimitIsReadOnlyInTheEndOfTheLog(t *testing.T) {
	log := "You've hit your weekly limit · resets Nov 15, 6pm\n" + strings.Repeat("work\n", limitTail)
	if found, _, _ := limitIn([]byte(log), time.Now()); found {
		t.Fatal("a limit message long before the end is not why the agent stopped")
	}
}

func TestHoldsAreSharedPerAgentAndBackOff(t *testing.T) {
	h := NewHolds()
	now := time.Date(2026, 11, 13, 9, 49, 0, 0, time.UTC)
	if got := h.QuickExit("claude", now); !got.Equal(now.Add(time.Minute)) {
		t.Fatalf("first quick exit holds until %v, want a minute", got)
	}
	if got := h.QuickExit("claude", now); !got.Equal(now.Add(2 * time.Minute)) {
		t.Fatalf("second holds until %v, want two minutes", got)
	}
	for range 10 {
		h.QuickExit("claude", now)
	}
	if got := h.QuickExit("claude", now); !got.Equal(now.Add(maxBackoff)) {
		t.Fatalf("the backoff stops at %v, got %v", maxBackoff, got)
	}
	if !h.Until("codex").IsZero() {
		t.Fatal("another agent isn't held")
	}
	h.Ran("claude")
	if got := h.QuickExit("claude", now.Add(time.Hour)); !got.Equal(now.Add(time.Hour + time.Minute)) {
		t.Fatalf("after a job that ran, the backoff starts again: %v", got)
	}

	reset := now.Add(48 * time.Hour)
	if got := h.Limit("claude", reset, now); !got.Equal(reset) {
		t.Fatalf("a limit holds until its reset: %v", got)
	}
	if got := h.QuickExit("claude", now); !got.Equal(reset) {
		t.Fatalf("a shorter backoff never shortens a hold: %v", got)
	}
	if got := h.Limit("codex", time.Time{}, now); !got.Equal(now.Add(limitHold)) {
		t.Fatalf("a limit with no reset holds an hour: %v", got)
	}
}

func TestALimitSendsTheJobBackAndHoldsTheRunners(t *testing.T) {
	r := newRig(t, Config{AfterHook: "report"})
	r.w.Local.Hooks = map[string]machine.Command{"report": self("hook", "report")}
	r.w.Holds = NewHolds()
	t.Setenv("HELPER_EXIT", "1")
	t.Setenv("HELPER_SAY", "You've hit your weekly limit · resets 11:59pm")
	before := time.Now()
	f := r.runJob(fakeJob{id: 140, kind: "claude", card: 7, prompt: "x"})
	if f.status != "requeue" || f.query.Get("trouble") != "limit" || f.exit != 1 {
		t.Fatalf("finish = %+v, want status requeue, trouble limit", f)
	}
	until, err := time.Parse(time.RFC3339, f.query.Get("until"))
	if err != nil || !until.After(before) {
		t.Fatalf("until = %q: the stated reset", f.query.Get("until"))
	}
	if !strings.Contains(f.query.Get("reason"), "weekly limit") {
		t.Fatalf("reason = %q: the agent's own line", f.query.Get("reason"))
	}
	if got := r.hooksRan(); !strings.Contains(got, "report exit=1 status=requeued") {
		t.Fatalf("the after hook hears it was requeued:\n%s", got)
	}
	// A second runner of the same agent, sharing the daemon's holds,
	// claims nothing until the reset.
	other := *r.w
	other.Runner.ID = 12
	var slept time.Duration
	other.Sleep = func(ctx context.Context, d time.Duration) error { slept = d; return context.Canceled }
	// A runner that isn't held would go on claiming: stop it, so the test
	// fails rather than hangs.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := other.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if slept <= 0 || slept > time.Until(until)+time.Second {
		t.Fatalf("the other runner waited %v, want until %v", slept, until)
	}
	if r.srv.claims[12] != 0 {
		t.Fatalf("the held runner claimed %d times", r.srv.claims[12])
	}
	if !strings.Contains(r.logged.String(), "taking no job until") {
		t.Fatalf("the daemon's log says why:\n%s", r.logged.String())
	}
}

func TestAQuickExitBeforeAToolCallSendsTheJobBack(t *testing.T) {
	r := newRig(t, Config{})
	r.w.QuickExit = time.Minute
	t.Setenv("HELPER_EXIT", "1")
	t.Setenv("HELPER_SAY", "Failed to authenticate. API Error: 403")
	f := r.runJob(fakeJob{id: 141, kind: "claude", card: 7, prompt: "x"})
	if f.status != "requeue" || f.query.Get("trouble") != "quick_exit" {
		t.Fatalf("finish = %+v, want requeue for a quick exit", f)
	}
	if !strings.Contains(f.body, "the job goes back to the queue, its card untouched") {
		t.Fatalf("the job's log says so:\n%s", f.body)
	}
	if until := r.w.Holds.Until("claude"); until.Sub(time.Now()) > time.Minute || until.Before(time.Now()) {
		t.Fatalf("held until %v, want about a minute", until)
	}
}

func TestAJobThatCalledAToolFailsAsTheCards(t *testing.T) {
	r := newRig(t, Config{})
	r.w.QuickExit = time.Minute
	r.w.Local.Transcripts = filepath.Join(t.TempDir(), "projects")
	url := "https://slipdock.example.com/boards/3/cards/42"
	t.Setenv("HELPER_TRANSCRIPT", filepath.Join(r.w.Local.Transcripts, "proj", "s.jsonl"))
	t.Setenv("HELPER_TRANSCRIPT_BODY", `{"text":"`+url+`"}`+"\n"+`{"message":{"content":[{"type":"tool_use","name":"Bash"}]}}`+"\n")
	t.Setenv("HELPER_EXIT", "1")
	f := r.runJob(fakeJob{id: 142, kind: "claude", card: 42, prompt: "x"})
	if f.status != "" || f.exit != 1 {
		t.Fatalf("finish = %+v, want an ordinary failure", f)
	}
	if !r.w.Holds.Until("claude").IsZero() {
		t.Fatal("a card's own failure holds nothing")
	}
}

func TestASlowFailureIsTheCards(t *testing.T) {
	r := newRig(t, Config{})
	r.w.QuickExit = time.Nanosecond // every job is slower than this
	t.Setenv("HELPER_EXIT", "2")
	f := r.runJob(fakeJob{id: 143, kind: "claude", card: 7, prompt: "x"})
	if f.status != "" || f.exit != 2 {
		t.Fatalf("finish = %+v, want an ordinary failure", f)
	}
}

func TestAJobThatSucceedsEndsTheBackoff(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Holds = NewHolds()
	r.w.Holds.QuickExit("claude", time.Now().Add(-time.Hour))
	r.w.Holds.QuickExit("claude", time.Now().Add(-time.Hour))
	if f := r.runJob(fakeJob{id: 144, kind: "claude", card: 7, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	now := time.Now()
	if got := r.w.Holds.QuickExit("claude", now); !got.Equal(now.Add(firstBackoff)) {
		t.Fatalf("the backoff started again: held until %v", got)
	}
}

func TestEndedAsRequeued(t *testing.T) {
	if got := endedAs(1, "requeue"); got != "requeued" {
		t.Fatalf("endedAs = %q", got)
	}
}
