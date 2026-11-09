package runner

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeGit answers git and gh as a repository whose origin is
// dadamsuk/slipdock and whose pull request 7 is open at head abc123.
type fakeGit struct {
	origin, state, head string
	authFails           bool
	mergeSays           string
	mergeFails          bool
	ran                 []string
}

func (g *fakeGit) exec(_ context.Context, dir, name string, args ...string) (string, error) {
	line := name + " " + strings.Join(args, " ")
	g.ran = append(g.ran, line)
	switch {
	case line == "git remote get-url origin":
		if g.origin == "" {
			return "", errors.New("no origin")
		}
		return g.origin + "\n", nil
	case line == "gh auth status":
		if g.authFails {
			return "not logged in", errors.New("exit 1")
		}
		return "", nil
	case strings.HasPrefix(line, "gh pr view 7") && strings.Contains(line, "state,headRefOid"):
		return g.state + " " + g.head + "\n", nil
	case strings.HasPrefix(line, "gh pr merge 7"):
		if g.mergeFails {
			return g.mergeSays, errors.New("exit 1")
		}
		return g.mergeSays, nil
	case strings.HasPrefix(line, "gh pr view 7") && strings.Contains(line, "mergeCommit"):
		return "fff999\n", nil
	}
	return "", errors.New("unexpected: " + line)
}

func mergeJob() *Job {
	return &Job{ID: 1, Kind: "merge", CardID: 42, MergePR: "https://github.com/dadamsuk/slipdock/pull/7", MergeCommit: "abc123"}
}

func TestMergeMergesTheAcceptedCommit(t *testing.T) {
	g := &fakeGit{origin: "git@" + "github.com:dadamsuk/slipdock.git", state: "OPEN", head: "abc123def"}
	var log []string
	sha, err := merge(context.Background(), g.exec, "/repo", mergeJob(), func(s string) { log = append(log, s) })
	if err != nil || sha != "fff999" {
		t.Fatalf("merge = %q, %v", sha, err)
	}
	want := "gh pr merge 7 --repo dadamsuk/slipdock --merge --match-head-commit abc123def --subject Merge PR 7: card #42"
	if !contains(g.ran, want) {
		t.Fatalf("ran:\n%s", strings.Join(g.ran, "\n"))
	}
	if !strings.Contains(strings.Join(log, "\n"), "merged https://github.com/dadamsuk/slipdock/pull/7 (head abc123def) as fff999") {
		t.Fatalf("log: %v", log)
	}
}

// #2637: a pull request already merged at the accepted commit is the merge
// the job wanted: it answers the merge commit and merges nothing again.
func TestMergeOfAPullRequestAlreadyMergedAtTheAcceptedCommit(t *testing.T) {
	g := &fakeGit{origin: "https://github.com/dadamsuk/slipdock.git", state: "MERGED", head: "ABC123def"}
	var log []string
	sha, err := merge(context.Background(), g.exec, "/repo", mergeJob(), func(s string) { log = append(log, s) })
	if err != nil || sha != "fff999" {
		t.Fatalf("merge = %q, %v", sha, err)
	}
	for _, line := range g.ran {
		if strings.HasPrefix(line, "gh pr merge") {
			t.Fatalf("merged again: %s", line)
		}
	}
	want := "merge: https://github.com/dadamsuk/slipdock/pull/7 was already merged at the accepted commit (head ABC123def) as fff999"
	if !contains(log, want) {
		t.Fatalf("log: %v", log)
	}
}

func TestMergeRefusesWhatDoesntCheckOut(t *testing.T) {
	cases := []struct {
		name string
		job  func(*Job)
		git  fakeGit
		code int
		want string
	}{
		{"no pr", func(j *Job) { j.MergePR = "" }, fakeGit{}, 2, "names no pull request"},
		{"no commit", func(j *Job) { j.MergeCommit = "" }, fakeGit{}, 2, "names no accepted commit"},
		{"not github", func(j *Job) { j.MergePR = "https://example.com/pull/7" }, fakeGit{}, 2, "not a GitHub pull request URL"},
		{"not a sha", func(j *Job) { j.MergeCommit = "abc; rm" }, fakeGit{}, 2, "is not a commit id"},
		{"no origin", nil, fakeGit{}, 2, "has no origin remote"},
		{"other repo", nil, fakeGit{origin: "https://github.com/someone/else.git"}, 2, "nothing merged"},
		{"gh signed out", nil, fakeGit{origin: "https://github.com/dadamsuk/slipdock", authFails: true}, 2, "gh is not signed in"},
		{"closed", nil, fakeGit{origin: "https://github.com/dadamsuk/slipdock", state: "CLOSED", head: "abc123"}, 2, "is CLOSED, not open"},
		{"merged at another head", nil, fakeGit{origin: "https://github.com/dadamsuk/slipdock", state: "MERGED", head: "999"}, 2,
			"https://github.com/dadamsuk/slipdock/pull/7 was already merged at head 999, not the accepted commit abc123; nothing merged"},
		{"head moved", nil, fakeGit{origin: "https://github.com/dadamsuk/slipdock", state: "OPEN", head: "999"}, 2, "not the accepted commit abc123"},
		{"gh refused", nil, fakeGit{origin: "https://x-token@" + "github.com/dadamsuk/slipdock.git", state: "OPEN", head: "abc123",
			mergeFails: true, mergeSays: "Pull request is not mergeable:\n the merge commit cannot be cleanly created"}, 3,
			"gh pr merge refused https://github.com/dadamsuk/slipdock/pull/7: Pull request is not mergeable: the merge commit cannot be cleanly created"},
	}
	for _, c := range cases {
		job := mergeJob()
		if c.job != nil {
			c.job(job)
		}
		g := c.git
		_, err := merge(context.Background(), g.exec, "/repo", job, func(string) {})
		var me *mergeExit
		if !errors.As(err, &me) || me.code != c.code || !strings.Contains(me.msg, c.want) {
			t.Errorf("%s: err = %v, want exit %d with %q", c.name, err, c.code, c.want)
		}
		for _, line := range g.ran {
			if strings.HasPrefix(line, "gh pr merge") && c.code == 2 {
				t.Errorf("%s: merged anyway", c.name)
			}
		}
	}
}

func TestAMergeJobReportsTheMergeCommit(t *testing.T) {
	r := newRig(t, Config{})
	g := &fakeGit{origin: "https://github.com/dadamsuk/slipdock.git", state: "OPEN", head: "abc123"}
	r.w.Exec = g.exec
	f := r.runJob(fakeJob{id: 150, kind: "merge", card: 42, pr: "https://github.com/dadamsuk/slipdock/pull/7", sha: "abc123"})
	if f.exit != 0 || f.merged != "fff999" {
		t.Fatalf("finish = %+v", f)
	}
	if r.agentSaw() != "" {
		t.Fatal("a merge runs no agent")
	}

	r = newRig(t, Config{})
	g = &fakeGit{origin: "https://github.com/dadamsuk/slipdock.git", state: "OPEN", head: "zzz"}
	r.w.Exec = g.exec
	f = r.runJob(fakeJob{id: 151, kind: "merge", card: 42, pr: "https://github.com/dadamsuk/slipdock/pull/7", sha: "abc123"})
	if f.exit != 2 || f.merged != "" || !strings.Contains(f.body, "nothing merged") {
		t.Fatalf("finish = %+v", f)
	}

	// no_merge in the local file: merge isn't a kind the runner takes.
	r = newRig(t, Config{})
	r.w.Local.NoMerge = true
	f = r.runJob(fakeJob{id: 152, kind: "merge", card: 42, pr: "https://github.com/dadamsuk/slipdock/pull/7", sha: "abc123"})
	if f.exit != 127 || r.srv.header(11).Get("X-Runner-Kinds") != "claude,verify,probe" {
		t.Fatalf("finish = %+v, kinds %q", f, r.srv.header(11).Get("X-Runner-Kinds"))
	}
}

func TestParseJobChecksWhatTheServerSent(t *testing.T) {
	h := http.Header{}
	h.Set("X-Job-Id", "x")
	if _, err := parseJob(h, nil); err == nil {
		t.Fatal("a job with no usable id was taken")
	}
	h.Set("X-Job-Id", "12")
	h.Set("X-Job-Kind", "Claude")
	h.Set("X-Card-Id", "-3")
	h.Set("X-Card-Url", "javascript:alert(1)")
	h.Set("X-Card-Profile", "anything")
	job, err := parseJob(h, []byte("prompt"))
	if err != nil {
		t.Fatal(err)
	}
	if job.ID != 12 || job.Kind != "" || job.CardID != 0 || job.CardURL != "" || job.Profile != "" || job.Prompt != "prompt" {
		t.Fatalf("job = %+v: each header is checked before use", job)
	}
}

func TestFinishTriesAgainAndTakesA404AsReported(t *testing.T) {
	codes := []int{500, 502, 200}
	var got []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.URL.RawQuery)
		code := codes[0]
		if len(codes) > 1 {
			codes = codes[1:]
		}
		w.WriteHeader(code)
	}))
	defer ts.Close()
	c := &Client{Server: ts.URL, Key: "sdm_test_key", HTTP: &http.Client{}}
	var waits []time.Duration
	sleep := func(d time.Duration) { waits = append(waits, d) }
	if err := c.Finish(context.Background(), 1, 2, 124, "timeout", "not-a-sha", nil, sleep); err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0] != "exit=124&status=timeout" || len(waits) != 2 || waits[1] != 4*time.Second {
		t.Fatalf("sent %v, waited %v", got, waits)
	}

	codes, got, waits = []int{404}, nil, nil
	if err := c.Finish(context.Background(), 1, 2, 0, "", "abc123", nil, sleep); err != nil || len(got) != 1 || got[0] != "exit=0&merged=abc123" {
		t.Fatalf("a 404 is a job the server doesn't hold: reported, err %v, sent %v", err, got)
	}

	codes, got = []int{503}, nil
	if err := c.Finish(context.Background(), 1, 2, 0, "", "", nil, sleep); err == nil || len(got) != 5 {
		t.Fatalf("five tries, then the error: err %v, tries %d", err, len(got))
	}
}
