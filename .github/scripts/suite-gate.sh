#!/usr/bin/env bash
# Does the post-merge suite need to run? (#1857)
#
# A pull request's CI tests the PR merged into main as main stood then
# (refs/pull/N/merge). When main hasn't moved since, the commit the merge puts
# on main has exactly that tree, and running the suite on it again tests
# nothing new. So the suite is skipped only when all of these hold:
#
#   - this is a push to main;
#   - a pull request's merge made this commit;
#   - that PR's latest CI run (ci.yml, on pull_request, for its final head)
#     has completed, and every one of its jobs passed;
#   - the commit that run tested has the same tree as this one. The run's
#     head_sha is the PR's head, not the merge it tested, so ci.yml puts the
#     tested sha in the run's name ("… · tested <sha>"), and it is read from
#     there.
#
# Anything else runs the suite: another event or ref, no PR, a red, missing
# or unfinished run, a run that doesn't say what it tested, another tree, or
# the API not answering. This script never fails: a gate that can't decide
# says run.
#
# In:  EVENT_NAME, REF, SHA, REPO (owner/name), GH_TOKEN for gh;
#      CI_WORKFLOW (default ci.yml).
# Out: run=true|false and note=<one line> on $GITHUB_OUTPUT; the decision on
#      $GITHUB_STEP_SUMMARY; the note on stdout.

set -u

workflow=${CI_WORKFLOW:-ci.yml}
short=${SHA:0:7}

decide() {
  local run=$1 note=$2 detail=$3
  echo "run=$run" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "note=$note" >> "${GITHUB_OUTPUT:-/dev/null}"
  {
    echo "### Suite"
    echo
    if [ "$run" = true ]; then echo "**Ran.** $detail"; else echo "**Skipped.** $detail"; fi
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "$note"
  exit 0
}

ran() { decide true "suite: ran ($1)" "$1"; }

api() { gh api "$1" 2>/dev/null; }

[ "${EVENT_NAME:-}" = push ] || ran "a ${EVENT_NAME:-unknown} run always tests"
[ "${REF:-}" = refs/heads/main ] || ran "a push to ${REF:-an unknown ref} always tests"

pulls=$(api "repos/$REPO/commits/$SHA/pulls") ||
  ran "the GitHub API didn't say which pull request made $short"

pr=$(jq -r --arg sha "$SHA" \
  'first(.[] | select(.merged_at != null and .merge_commit_sha == $sha) | "\(.number) \(.head.sha)") // empty' \
  <<< "$pulls" 2>/dev/null) || ran "the GitHub API's answer for $short's pull request didn't parse"
[ -n "$pr" ] || ran "no pull request's merge made $short"
read -r number head <<< "$pr"

runs=$(api "repos/$REPO/actions/workflows/$workflow/runs?event=pull_request&head_sha=$head&per_page=100") ||
  ran "the GitHub API didn't list PR #$number's CI runs"

latest=$(jq -c '.workflow_runs | sort_by(.created_at, .id) | last // empty' <<< "$runs" 2>/dev/null) ||
  ran "PR #$number's CI runs didn't parse"
[ -n "$latest" ] || ran "PR #$number has no CI run on its last commit"

id=$(jq -r .id <<< "$latest")
url=$(jq -r '.html_url // ""' <<< "$latest")
status=$(jq -r .status <<< "$latest")
conclusion=$(jq -r '.conclusion // "none"' <<< "$latest")
title=$(jq -r '.display_title // ""' <<< "$latest")

[ "$status" = completed ] || ran "PR #$number's CI run $id is $status, not finished"
[ "$conclusion" = success ] || ran "PR #$number's CI run $id ended $conclusion"

tested=$(grep -Eo 'tested [0-9a-f]{40}$' <<< "$title" | cut -d' ' -f2)
[ -n "$tested" ] || ran "PR #$number's CI run $id doesn't say which commit it tested"

jobs=$(api "repos/$REPO/actions/runs/$id/jobs?per_page=100") ||
  ran "the GitHub API didn't list the jobs of PR #$number's CI run $id"
failed=$(jq -r '[.jobs[] | select(.conclusion != "success") | .name] | join(", ")' <<< "$jobs" 2>/dev/null) ||
  ran "the jobs of PR #$number's CI run $id didn't parse"
count=$(jq -r '.jobs | length' <<< "$jobs")
[ "$count" -gt 0 ] || ran "PR #$number's CI run $id has no jobs"
[ -z "$failed" ] || ran "not every job of PR #$number's CI run $id passed: $failed"

tested_tree=$(api "repos/$REPO/git/commits/$tested" | jq -r '.tree.sha // empty' 2>/dev/null)
[ -n "$tested_tree" ] || ran "the GitHub API didn't give the tree of $tested, the commit PR #$number's CI tested"
head_tree=$(git rev-parse "$SHA^{tree}" 2>/dev/null || api "repos/$REPO/git/commits/$SHA" | jq -r '.tree.sha // empty' 2>/dev/null)
[ -n "$head_tree" ] || ran "the tree of $short couldn't be read"

[ "$tested_tree" = "$head_tree" ] ||
  ran "main moved after PR #$number's CI run $id: it tested ${tested:0:7}, whose tree differs from $short's"

decide false "suite: passed on PR #$number at ${tested:0:7}, same tree" \
  "Passed on PR #$number, CI run [$id]($url), at \`$tested\`: the same tree as \`$SHA\` (\`$head_tree\`)."
