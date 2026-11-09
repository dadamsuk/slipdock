package runner

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// reads is how often the worker read the skills or resolved the CLI
// through the executor.
func (r *recorder) reads() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, c := range r.calls {
		if c == "files" || c == "resolve slipdock" {
			n++
		}
	}
	return n
}

func skillSum(body string) string {
	sum := sha256.Sum256([]byte(body))
	return "slipdock=" + hex.EncodeToString(sum[:])
}

// driftRig is a worker whose executor is named name, a skill in its home
// saying body, and a clock the test moves.
func driftRig(t *testing.T, name, body string) (*rig, *recorder, string, *time.Time) {
	t.Helper()
	r := newRig(t, Config{})
	me, _ := executor.New(executor.Me, executor.Settings{GOOS: runtime.GOOS})
	rec := &recorder{Executor: me, home: t.TempDir()}
	r.w.Executor = named{rec, name}
	clock := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	r.w.Now = func() time.Time { return clock }
	skill := filepath.Join(rec.home, ".claude", "skills", "slipdock", "SKILL.md")
	if err := os.MkdirAll(filepath.Dir(skill), 0o755); err != nil {
		t.Fatal(err)
	}
	writeSkill(t, skill, body)
	r.w.defaults()
	return r, rec, skill, &clock
}

func writeSkill(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestTheUserExecutorKeepsTheDriftSumsUntilTheyExpire(t *testing.T) {
	r, rec, skill, clock := driftRig(t, executor.User, "one")
	if got := r.w.drift().skills; got != skillSum("one") {
		t.Fatalf("first claim's skills = %q", got)
	}
	first := rec.reads()
	if first == 0 {
		t.Fatal("the first claim read nothing through the executor")
	}

	// An idle runner's next claims reuse them: no read as the account.
	writeSkill(t, skill, "two")
	*clock = clock.Add(driftEvery - time.Second)
	for range 5 {
		if got := r.w.drift().skills; got != skillSum("one") {
			t.Fatalf("a claim within %s read the skills again: %q", driftEvery, got)
		}
	}
	if rec.reads() != first {
		t.Fatalf("claims within %s read as the account: %v", driftEvery, rec.calls)
	}

	// Once they're DriftEvery old they're read again.
	*clock = clock.Add(time.Second)
	if got := r.w.drift().skills; got != skillSum("two") {
		t.Fatalf("after %s the skills are read again: %q", driftEvery, got)
	}
	if rec.reads() == first {
		t.Fatal("the expired sums weren't read through the executor")
	}
}

func TestTheUserExecutorReadsTheDriftSumsAgainAfterAJob(t *testing.T) {
	r, _, skill, _ := driftRig(t, executor.User, "before")
	// The clock never moves, so only the job can make the worker read
	// them again: the job rewrites the skill, and a claim after it must
	// report the new one.
	t.Setenv("HELPER_TRANSCRIPT", skill)
	t.Setenv("HELPER_TRANSCRIPT_BODY", "after")
	r.srv.add(fakeJob{id: 401, runner: r.w.Runner.ID, kind: "claude", card: 1, prompt: "x"})
	r.run(func() bool {
		_, done := r.srv.finish(401)
		return done && r.srv.header(11).Get("X-Runner-Skills") == skillSum("after")
	})
}

func TestOtherExecutorsReadTheDriftSumsOnEveryClaim(t *testing.T) {
	for _, name := range []string{executor.Me, executor.Confined} {
		t.Run(name, func(t *testing.T) {
			r, rec, skill, _ := driftRig(t, name, "one")
			r.w.drift()
			first := rec.reads()
			writeSkill(t, skill, "two")
			if got := r.w.drift().skills; got != skillSum("two") {
				t.Fatalf("the next claim's skills = %q: want them read fresh", got)
			}
			if rec.reads() <= first {
				t.Fatalf("the next claim didn't read through the executor: %v", rec.calls)
			}
			if !r.w.sums.at.IsZero() {
				t.Fatal("an executor other than user kept the sums")
			}
		})
	}
}

func TestTheDriftSumsWithoutAnExecutor(t *testing.T) {
	r := newRig(t, Config{})
	r.w.defaults()
	r.w.Executor, r.w.Home = nil, t.TempDir()
	if got := r.w.drift(); got.skills != "none" || got.cli != "none" {
		t.Fatalf("no skills and no CLI read as none: %+v", got)
	}
}
