package runner

import (
	"context"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

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
		{"an unknown month", "You've hit your weekly limit · resets Foo 15, 6pm", true, time.Time{}},
		{"no day 32", "You've hit your weekly limit · resets Nov 32, 6pm", true, time.Time{}},
		{"no day 0", "You've hit your weekly limit · resets Nov 0, 6pm", true, time.Time{}},
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

// An unknown month is no reset, whatever the date: from mid-December a
// month read as zero (December of the year before, rolled to this one)
// would land inside the hold's reach.
func TestAnUnknownMonthIsNoResetInDecember(t *testing.T) {
	now := time.Date(2026, 12, 10, 9, 0, 0, 0, time.UTC)
	if found, _, at := limitIn([]byte("You've hit your weekly limit · resets Foo 15, 6pm"), now); !found || !at.IsZero() {
		t.Fatalf("found = %v, reset = %v: want the limit with no reset", found, at)
	}
}

// A day past the month's last isn't rolled into the next month's.
func TestNoSuchDayIsNoReset(t *testing.T) {
	now := time.Date(2026, 11, 28, 9, 0, 0, 0, time.UTC)
	for _, line := range []string{"You've hit your weekly limit · resets Nov 31, 6pm", "You've hit your weekly limit · resets Nov 32, 6pm", "You've hit your weekly limit · resets Dec 0, 6pm"} {
		if _, _, at := limitIn([]byte(line), now); !at.IsZero() {
			t.Fatalf("%q resets %v: there is no such day", line, at)
		}
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
	if got := h.QuickExit("claude", now, ""); !got.Equal(now.Add(time.Minute)) {
		t.Fatalf("first quick exit holds until %v, want a minute", got)
	}
	if got := h.QuickExit("claude", now, ""); !got.Equal(now.Add(2 * time.Minute)) {
		t.Fatalf("second holds until %v, want two minutes", got)
	}
	for range 10 {
		h.QuickExit("claude", now, "")
	}
	if got := h.QuickExit("claude", now, ""); !got.Equal(now.Add(maxBackoff)) {
		t.Fatalf("the backoff stops at %v, got %v", maxBackoff, got)
	}
	if !h.Until("codex").IsZero() {
		t.Fatal("another agent isn't held")
	}
	h.Ran("claude")
	if got := h.QuickExit("claude", now.Add(time.Hour), ""); !got.Equal(now.Add(time.Hour + time.Minute)) {
		t.Fatalf("after a job that ran, the backoff starts again: %v", got)
	}

	reset := now.Add(48 * time.Hour)
	if got := h.Limit("claude", reset, now, ""); !got.Equal(reset) {
		t.Fatalf("a limit holds until its reset: %v", got)
	}
	if got := h.QuickExit("claude", now, ""); !got.Equal(reset) {
		t.Fatalf("a shorter backoff never shortens a hold: %v", got)
	}
	if got := h.Limit("codex", time.Time{}, now, ""); !got.Equal(now.Add(limitHold)) {
		t.Fatalf("a limit with no reset holds an hour: %v", got)
	}
	if got := h.Limit("claude", now.Add(time.Hour), now, "a sooner one"); !got.Equal(reset) {
		t.Fatalf("a sooner reset never shortens a longer hold: %v", got)
	}
}

func TestHeldSaysWhyAndUntilWhen(t *testing.T) {
	h := NewHolds()
	now := time.Date(2026, 11, 13, 9, 49, 0, 0, time.UTC)
	if _, held := h.Held("claude", now); held {
		t.Fatal("nothing holds a new set")
	}
	h.QuickExit("claude", now, "exited 1")
	tr, held := h.Held("claude", now)
	if !held || tr.kind != "quick_exit" || tr.reason != "exited 1" || !tr.until.Equal(now.Add(firstBackoff)) {
		t.Fatalf("held = %v, %+v", held, tr)
	}
	reset := now.Add(5 * time.Hour)
	h.Limit("claude", reset, now, "the limit")
	if tr, _ := h.Held("claude", now); tr.kind != "limit" || tr.reason != "the limit" || !tr.until.Equal(reset) {
		t.Fatalf("the limit's hold: %+v", tr)
	}
	// A backoff inside the hold leaves it the limit's.
	h.QuickExit("claude", now, "exited 1")
	if tr, _ := h.Held("claude", now); tr.kind != "limit" {
		t.Fatalf("a shorter backoff took the hold's reason: %+v", tr)
	}
	if _, held := h.Held("claude", reset); held {
		t.Fatal("the hold ends at its time")
	}
}

// holdOnClaim sets a hold once a claim has been sent, before its answer
// reaches the worker: a sibling runner hitting the limit while this one
// waits in its claim's long poll.
type holdOnClaim struct {
	next http.RoundTripper
	hold func()
}

func (t holdOnClaim) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.next.RoundTrip(req)
	if err == nil && req.URL.Path == "/api/runner/claim" && resp.StatusCode == 200 {
		t.hold()
	}
	return resp, err
}

// A runner already waiting in its claim when a sibling hits the limit (the
// pool woken by the requeue hands it the job at once) gives the job back
// unrun: the agent isn't started, the job goes back as the hold's trouble,
// and the backoff isn't doubled by it.
func TestAJobClaimedWhileHeldIsGivenBackUnrun(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Holds = NewHolds()
	reset := time.Now().Add(3 * time.Hour).UTC().Truncate(time.Second)
	r.w.Client.HTTP.Transport = holdOnClaim{r.w.Client.HTTP.Transport, func() {
		r.w.Holds.Limit("claude", reset, time.Now(), "the agent's limit: You've hit your weekly limit")
	}}
	f := r.runJob(fakeJob{id: 150, kind: "claude", card: 7, prompt: "x"})
	if f.status != "requeue" || f.query.Get("trouble") != "limit" || f.query.Get("until") != reset.Format(time.RFC3339) {
		t.Fatalf("finish = %+v (%v), want it given back as the limit until %v", f, f.query, reset)
	}
	if !strings.Contains(f.query.Get("reason"), "weekly limit") || !strings.Contains(f.body, "given back unrun") {
		t.Fatalf("reason %q, body %q", f.query.Get("reason"), f.body)
	}
	if saw := r.agentSaw(); saw != "" {
		t.Fatalf("the agent ran for a job claimed while held:\n%s", saw)
	}
	r.w.Holds.mu.Lock()
	backoff := r.w.Holds.backoff["claude"]
	r.w.Holds.mu.Unlock()
	if backoff != 0 {
		t.Fatalf("a job given back unrun doubled the backoff to %v", backoff)
	}
}

// A merge, a release or a probe doesn't run the agent, so a hold doesn't
// stop it.
func TestAMergeClaimedWhileHeldStillRuns(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Holds = NewHolds()
	r.w.Holds.Limit("claude", time.Now().Add(time.Hour), time.Now(), "")
	r.w.defaults()
	for i, kind := range []string{"merge", ReleaseKind, ProbeKind} {
		if r.w.giveBack(context.Background(), &Job{ID: int64(160 + i), Kind: kind}) {
			t.Fatalf("a %s job was given back", kind)
		}
	}
	if !r.w.giveBack(context.Background(), &Job{ID: 152, Kind: "claude"}) {
		t.Fatal("an agent job was run while held")
	}
	if f, _ := r.srv.finish(152); f.status != "requeue" {
		t.Fatalf("finish = %+v", f)
	}
}

// A job given back under a quick-exit hold goes back as that hold's
// trouble, so the server's one alert for the episode keeps its cause.
func TestAJobGivenBackUnderABackoffIsAQuickExit(t *testing.T) {
	r := newRig(t, Config{})
	r.w.Holds = NewHolds()
	now := time.Now()
	r.w.Holds.QuickExit("claude", now, "the agent exited 1 in 2s, before a tool call")
	r.w.defaults()
	if !r.w.giveBack(context.Background(), &Job{ID: 155, Kind: "claude"}) {
		t.Fatal("an agent job was run while backed off")
	}
	f, _ := r.srv.finish(155)
	until := now.Add(firstBackoff).UTC().Format(time.RFC3339)
	if f.status != "requeue" || f.query.Get("trouble") != "quick_exit" || f.query.Get("until") != until ||
		f.query.Get("reason") != "the agent exited 1 in 2s, before a tool call" {
		t.Fatalf("finish = %+v (%v), want quick_exit until %s with the hold's reason", f, f.query, until)
	}
}

// A job stopped by its timeout is the job's end, not trouble, however
// quickly it was stopped and whatever its log says.
func TestATimedOutJobIsNotTrouble(t *testing.T) {
	r, _ := treeRig(t, Config{})
	r.w.Holds = NewHolds()
	r.w.QuickExit = time.Hour // the timeout comes well inside it
	r.w.Timeout = 300 * time.Millisecond
	f := r.runJob(fakeJob{id: 153, kind: "claude", card: 7, prompt: "x"})
	if f.status != "timeout" {
		t.Fatalf("finish = %+v, want timeout", f)
	}
	if _, held := r.w.Holds.Held("claude", time.Now()); held {
		t.Fatal("a timeout held the runners")
	}
}

// clip never cuts inside a character, and leaves a string of exactly n
// bytes whole.
func TestClipKeepsWholeCharacters(t *testing.T) {
	s := "a" + strings.Repeat("é", 150) // byte 200 is the second byte of an é
	if got := clip(s, 200); len(got) != 199 || !utf8.ValidString(got) || !strings.HasPrefix(s, got) {
		t.Fatalf("clip = %d bytes, valid %v: want 199 bytes, whole characters", len(got), utf8.ValidString(got))
	}
	exact := strings.Repeat("x", 200)
	if got := clip(exact, 200); got != exact {
		t.Fatalf("clip of 200 bytes = %d bytes, want it whole", len(got))
	}
	if got := clip("short", 200); got != "short" {
		t.Fatalf("clip = %q", got)
	}
}

func TestTheRequeueReasonIsClipped(t *testing.T) {
	r := newRig(t, Config{})
	long := strings.Repeat("é", 150) // 300 bytes
	if err := r.w.Client.Requeue(context.Background(), 11, 154, 1, "limit", time.Now(), long, nil, func(time.Duration) {}); err != nil {
		t.Fatal(err)
	}
	f, _ := r.srv.finish(154)
	got := f.query.Get("reason")
	if len(got) > 200 || !utf8.ValidString(got) || !strings.HasPrefix(long, got) || len(got) < 199 {
		t.Fatalf("reason = %d bytes %q, want the first 200 bytes, whole characters", len(got), got)
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
	r.w.Holds.QuickExit("claude", time.Now().Add(-time.Hour), "")
	r.w.Holds.QuickExit("claude", time.Now().Add(-time.Hour), "")
	if f := r.runJob(fakeJob{id: 144, kind: "claude", card: 7, prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	now := time.Now()
	if got := r.w.Holds.QuickExit("claude", now, ""); !got.Equal(now.Add(firstBackoff)) {
		t.Fatalf("the backoff started again: held until %v", got)
	}
}

func TestEndedAsRequeued(t *testing.T) {
	if got := endedAs(1, "requeue"); got != "requeued" {
		t.Fatalf("endedAs = %q", got)
	}
}
