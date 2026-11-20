package runner

import (
	"context"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// execFunc runs a program in dir and returns what it printed (stdout and
// stderr together). A var in the worker so tests can stand in for git and gh.
type execFunc func(ctx context.Context, dir, name string, args ...string) (string, error)

var prURL = regexp.MustCompile(`^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)/*$`)

// mergeExit is a merge refused before anything changed (2), one gh
// refused (3), as the shell runner's job_merge says them, or one that
// waits for a person's approval (4, #3519).
type mergeExit struct {
	code int
	msg  string
}

func (e *mergeExit) Error() string { return e.msg }

// merge is the built-in merge kind (#1656), the shell runner's job_merge:
// the pull request and the accepted commit are data from the server,
// checked here before use. It merges only a pull request in dir's own
// origin, still open, whose head is the accepted commit, and answers the
// merge commit; one already merged at that commit answers its merge
// commit too (#2637). log gets what a person reads afterwards.
func merge(ctx context.Context, run execFunc, dir string, job *Job, log func(string)) (string, error) {
	fail := func(code int, format string, a ...any) (string, error) {
		return "", &mergeExit{code, "merge: " + fmt.Sprintf(format, a...)}
	}
	pr, want := job.MergePR, job.MergeCommit
	if pr == "" {
		return fail(2, "the card names no pull request (its evidence has no PR URL)")
	}
	if want == "" {
		return fail(2, "the card names no accepted commit")
	}
	m := prURL.FindStringSubmatch(pr)
	if m == nil {
		return fail(2, "%s is not a GitHub pull request URL", pr)
	}
	prRepo, num := m[1], m[2]
	if !isHex(want) {
		return fail(2, "the accepted commit %s is not a commit id", want)
	}
	origin, err := run(ctx, dir, "git", "remote", "get-url", "origin")
	if err != nil {
		return fail(2, "%s has no origin remote", dir)
	}
	if !strings.EqualFold(repoOf(strings.TrimSpace(origin)), prRepo) {
		return fail(2, "the pull request is in %s, but this runner's repository is %s; nothing merged", prRepo, strings.TrimSpace(origin))
	}
	if _, err := run(ctx, dir, "gh", "auth", "status"); err != nil {
		return fail(2, "gh is not signed in (run gh auth login)")
	}
	info, err := run(ctx, dir, "gh", "pr", "view", num, "--repo", prRepo, "--json", "state,headRefOid", "--jq", `.state + " " + .headRefOid`)
	if err != nil {
		return fail(2, "could not read %s: %s", pr, oneLine(info))
	}
	state, head, _ := strings.Cut(strings.TrimSpace(info), " ")
	if state == "MERGED" {
		return alreadyMerged(ctx, run, dir, pr, prRepo, num, head, want, log)
	}
	if state != "OPEN" {
		return fail(2, "%s is %s, not open; nothing merged", pr, state)
	}
	if !strings.HasPrefix(strings.ToLower(head), strings.ToLower(want)) {
		return fail(2, "%s's head is %s, not the accepted commit %s (it moved after the card was accepted); nothing merged", pr, head, want)
	}
	if hit, err := needsApproval(ctx, run, dir, prRepo, num, job); err != nil {
		return fail(2, "could not list %s's files: %v; nothing merged", pr, err)
	} else if len(hit) > 0 {
		return fail(4, "%s %s changes %s, so a person approves it first; nothing merged",
			NeedsApproval, pr, strings.Join(hit, ", "))
	}
	card := "?"
	if job.CardID > 0 {
		card = fmt.Sprint(job.CardID)
	}
	// gh's own words are the reason (#1666): a conflict reads differently
	// from a failing check or branch protection.
	said, err := run(ctx, dir, "gh", "pr", "merge", num, "--repo", prRepo, "--merge", "--match-head-commit", head,
		"--subject", fmt.Sprintf("Merge PR %s: card #%s", num, card))
	if err != nil {
		reason := oneLine(said)
		if reason == "" {
			reason = "gh gave no reason"
		}
		return fail(3, "gh pr merge refused %s: %s", pr, reason)
	}
	if s := strings.TrimSpace(said); s != "" {
		log(s)
	}
	sha := mergeCommit(ctx, run, dir, prRepo, num)
	log(fmt.Sprintf("merge: merged %s (head %s) as %s", pr, head, shownSha(sha)))
	return sha, nil
}

// alreadyMerged is a pull request somebody merged before this job got to it
// (#2637): merged at the accepted commit, it is the merge the job wanted,
// so it answers the merge commit; merged at another head, it fails and
// says which, for a person to look at.
func alreadyMerged(ctx context.Context, run execFunc, dir, pr, prRepo, num, head, want string, log func(string)) (string, error) {
	if !strings.HasPrefix(strings.ToLower(head), strings.ToLower(want)) {
		return "", &mergeExit{2, fmt.Sprintf("merge: %s was already merged at head %s, not the accepted commit %s; nothing merged", pr, head, want)}
	}
	sha := mergeCommit(ctx, run, dir, prRepo, num)
	log(fmt.Sprintf("merge: %s was already merged at the accepted commit (head %s) as %s", pr, head, shownSha(sha)))
	return sha, nil
}

// mergeCommit is the pull request's merge commit, "" if gh doesn't say.
func mergeCommit(ctx context.Context, run execFunc, dir, prRepo, num string) string {
	sha, _ := run(ctx, dir, "gh", "pr", "view", num, "--repo", prRepo, "--json", "mergeCommit", "--jq", ".mergeCommit.oid")
	return strings.TrimSpace(sha)
}

func shownSha(sha string) string {
	if sha == "" {
		return "an unknown commit"
	}
	return sha
}

// repoOf is owner/name from a GitHub remote URL (https or ssh).
func repoOf(origin string) string {
	r := strings.TrimSuffix(strings.TrimRight(origin, "/"), ".git")
	if m := remoteURL.FindStringSubmatch(r); m != nil {
		return m[1]
	}
	return r
}

// remoteURL is a GitHub remote, owner/name after the host: ssh (scp-like, or ssh://),
// or https with or without a token in it.
var remoteURL = regexp.MustCompile(`^(?:ssh://git@github\.com/|git@github\.com:|https://(?:[^@/]*@)?github\.com/)(.+)$`)

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// NeedsApproval opens the merge line of a pull request that changes a
// sensitive file nobody has approved yet (#3519): the server holds the
// card for a person when it reads it.
const NeedsApproval = "needs a person's approval:"

// needsApproval is the pull request's files that match the board's
// sensitive paths, when a person hasn't approved its merge: none when the
// server sent no paths (an older one) or the approval. A pull request with
// more files than gh lists counts as one that needs it.
func needsApproval(ctx context.Context, run execFunc, dir, prRepo, num string, job *Job) ([]string, error) {
	if len(job.SensitivePaths) == 0 || job.MergeApproved {
		return nil, nil
	}
	out, err := run(ctx, dir, "gh", "pr", "view", num, "--repo", prRepo, "--json", "changedFiles,files",
		"--jq", ".changedFiles, .files[].path")
	if err != nil {
		return nil, fmt.Errorf("%s", oneLine(out))
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	count, err := strconv.Atoi(strings.TrimSpace(lines[0]))
	if err != nil {
		return nil, fmt.Errorf("gh said %q", oneLine(out))
	}
	var files, hit []string
	for _, f := range lines[1:] {
		if f = strings.TrimSpace(f); f != "" {
			files = append(files, f)
		}
	}
	for _, f := range files {
		if matchAny(job.SensitivePaths, f) {
			hit = append(hit, f)
		}
	}
	if len(files) < count {
		hit = append(hit, fmt.Sprintf("%d more files gh doesn't list", count-len(files)))
	}
	return hit, nil
}

func matchAny(globs []string, path string) bool {
	for _, g := range globs {
		if globMatch(g, path) {
			return true
		}
	}
	return false
}

// globMatch matches a path against a glob as the server's handbook does:
// ** is any run of folders (none included), * any run of characters but /,
// and a glob matches the files under a folder it names.
func globMatch(glob, path string) bool {
	glob = strings.TrimPrefix(strings.TrimSpace(glob), "./")
	path = strings.TrimPrefix(path, "./")
	if glob == "" {
		return false
	}
	return matchParts(strings.Split(glob, "/"), strings.Split(path, "/"))
}

func matchParts(glob, path []string) bool {
	if len(glob) == 0 {
		return len(path) == 0
	}
	if glob[0] == "**" {
		for i := 0; i <= len(path); i++ {
			if matchParts(glob[1:], path[i:]) {
				return true
			}
		}
		return false
	}
	if len(path) == 0 {
		return false
	}
	if ok, _ := filepath.Match(glob[0], path[0]); !ok {
		return false
	}
	if len(glob) == 1 {
		// A folder the glob names holds the files under it.
		return true
	}
	return matchParts(glob[1:], path[1:])
}
