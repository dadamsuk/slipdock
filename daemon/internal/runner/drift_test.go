package runner

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"runtime"
	"strings"
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

// skillSum is what a claim says of a slipdock skill that is one SKILL.md
// saying body: the sum of its one line, written out here so the format
// isn't taken from the code under test.
func skillSum(body string) string {
	file := sha256.Sum256([]byte(body))
	sum := sha256.Sum256([]byte("SKILL.md\x00" + hex.EncodeToString(file[:]) + "\n"))
	return "slipdock=" + hex.EncodeToString(sum[:])
}

// skillsIn writes files (path under the skills folder to text) in a new
// folder and gives what a claim says of it.
func skillsIn(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for rel, body := range files {
		p := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		writeSkill(t, p, body)
	}
	return installedSkills(executor.LocalFiles, dir)
}

// The sum is of every file of a skill (#3006): the server computes the
// same from what it serves, and its test (runners_drift_test.exs) pins
// the same files to the same sum.
func TestASkillsSumIsOfEveryFileOfIt(t *testing.T) {
	const want = "slipdock-wiki=7b8e3adc347d9f4ebe788382b9924ff5b882e9705e89cd1fb3e20d40433d7ab7"
	whole := map[string]string{
		"slipdock-wiki/SKILL.md":             "a skill\n",
		"slipdock-wiki/references/api.md":    "the api\n",
		"slipdock-wiki/references/markup.md": "the markup\n",
	}
	if got := skillsIn(t, whole); got != want {
		t.Fatalf("the skill's sum = %q, want %q", got, want)
	}
	with := func(change func(map[string]string)) map[string]string {
		files := map[string]string{}
		for k, v := range whole {
			files[k] = v
		}
		change(files)
		return files
	}

	// Its SKILL.md as it was, and a reference changed, missing or extra,
	// or a file beside the SKILL.md that the server never sent.
	for name, files := range map[string]map[string]string{
		"a reference changed": with(func(f map[string]string) { f["slipdock-wiki/references/api.md"] = "an older api\n" }),
		"a reference missing": with(func(f map[string]string) { delete(f, "slipdock-wiki/references/markup.md") }),
		"a reference extra":   with(func(f map[string]string) { f["slipdock-wiki/references/old.md"] = "left behind\n" }),
		"a reference renamed": with(func(f map[string]string) {
			f["slipdock-wiki/references/apis.md"] = f["slipdock-wiki/references/api.md"]
			delete(f, "slipdock-wiki/references/api.md")
		}),
		"a file beside the SKILL.md": with(func(f map[string]string) { f["slipdock-wiki/notes.md"] = "mine\n" }),
		"the SKILL.md changed":       with(func(f map[string]string) { f["slipdock-wiki/SKILL.md"] = "another skill\n" }),
	} {
		if got := skillsIn(t, files); got == want || !strings.HasPrefix(got, "slipdock-wiki=") || len(got) != len(want) {
			t.Errorf("%s: the sum = %q, want another than the whole skill's", name, got)
		}
	}

	// The same text reads the same: CRLF line endings, a dot file (an
	// editor's, a desktop's) and a folder inside references change nothing.
	for name, files := range map[string]map[string]string{
		"CRLF line endings": with(func(f map[string]string) {
			f["slipdock-wiki/SKILL.md"] = "a skill\r\n"
			f["slipdock-wiki/references/api.md"] = "the api\r\n"
		}),
		"a dot file": with(func(f map[string]string) {
			f["slipdock-wiki/.DS_Store"] = "x"
			f["slipdock-wiki/references/.api.md.swp"] = "x"
		}),
		"a folder in references": with(func(f map[string]string) { f["slipdock-wiki/references/deep/more.md"] = "x" }),
	} {
		if got := skillsIn(t, files); got != want {
			t.Errorf("%s: the sum = %q, want %q", name, got, want)
		}
	}
}

func TestASkillThatIsOneFileAndTheSkillsInOrder(t *testing.T) {
	got := skillsIn(t, map[string]string{
		"slipdock-work/SKILL.md":         "a skill\n",
		"slipdock/SKILL.md":              "a skill\n",
		"slipdock-wiki/references/a.md":  "a folder with no SKILL.md is no skill\n",
		"other/SKILL.md":                 "not a slipdock skill\n",
		"slipdock-loop/SKILL.md/nothing": "a SKILL.md that is a folder doesn't read\n",
	})
	const one = "9a6d16f5221aff4e3b9730271e8ec803c48f8ce699256b2e332010dee8ede178"
	if want := "slipdock=" + one + ",slipdock-work=" + one; got != want {
		t.Fatalf("the skills = %q, want %q", got, want)
	}
	// Not the sum of the SKILL.md alone, which is what a daemon from before
	// #3006 says and the server still reads as current.
	file := sha256.Sum256([]byte("a skill\n"))
	if one == hex.EncodeToString(file[:]) {
		t.Fatal("a one-file skill's sum is its SKILL.md's own")
	}
	if got := skillsIn(t, map[string]string{"notes.md": "no skills here\n"}); got != "none" {
		t.Fatalf("no skills = %q, want none", got)
	}
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
