#!/usr/bin/env bash
# What a ci.yml run needs to run (#2832). Each job is billed in whole
# minutes, so a pull request runs only the jobs its change can break:
#
#   - the Elixir suite (the four partitions and coverage) when anything
#     outside docs, the CLI and the daemon changed;
#   - the repo checks (test/repo_checks.txt, with a compile) in its place
#     when it doesn't: a change to docs/**, priv/skills/**, any *.md,
#     cli/** or daemon/** alone. They are the tests that read those files;
#   - the cli job when cli/** changed, the daemon job when daemon/** did;
#   - everything (on Linux) when .github/** changed: a workflow or one of
#     its scripts.
#
# Anything but a pull request ignores the paths. A run release.yml calls
# (a push to main or a v* tag) runs everything unless the post-merge gate
# said the pull request's CI already passed on this tree (SUITE=false);
# then it runs only the static checks, which ci.yml runs on every event
# but a pull request and the schedule. The nightly schedule runs the
# daemon alone.
#
# The daemon runs on Linux (CI_RUNNER, or GitHub's ubuntu-latest), and on
# macOS and Windows too only on a v* tag, the nightly schedule or a manual
# dispatch: those are GitHub's runners, paid by the minute.
#
# A diff that can't be read, or reads empty, runs everything: this script
# never fails, and when it can't decide it says run.
#
# In:  EVENT_NAME, REF; BASE and HEAD (a pull request's base and head
#      shas, the history fetched); SUITE (false: the gate skipped the
#      suite); CI_RUNNER.
# Out: suite, repo_checks, cli, daemon (true|false) and daemon_os (a JSON
#      list) on $GITHUB_OUTPUT; the decision on $GITHUB_STEP_SUMMARY.

set -u

linux=${CI_RUNNER:-ubuntu-latest}
case "${EVENT_NAME:-}:${REF:-}" in
  schedule:* | workflow_dispatch:* | *:refs/tags/v*)
    daemon_os="[\"$linux\", \"macos-latest\", \"windows-latest\"]" ;;
  *)
    daemon_os="[\"$linux\"]" ;;
esac

decide() {
  local suite=$1 repo_checks=$2 cli=$3 daemon=$4 why=$5
  {
    echo "suite=$suite"
    echo "repo_checks=$repo_checks"
    echo "cli=$cli"
    echo "daemon=$daemon"
    echo "daemon_os=$daemon_os"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
  {
    echo "### What runs"
    echo
    echo "$why"
    echo
    echo "suite: $suite · repo checks: $repo_checks · cli: $cli · daemon: $daemon on $daemon_os"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "suite=$suite repo_checks=$repo_checks cli=$cli daemon=$daemon daemon_os=$daemon_os"
  exit 0
}

everything() { decide true false true true "$1"; }

case "${EVENT_NAME:-}" in
  pull_request) ;;
  schedule) decide false false false true "The nightly run: the daemon alone, on every OS." ;;
  *)
    if [ "${SUITE:-}" = false ]; then
      decide false false false false "The pull request's CI passed on this tree: the static checks alone."
    fi
    everything "A ${EVENT_NAME:-unknown} run tests everything."
    ;;
esac

# Both paths of a move: without --no-renames a file moved under docs/ (or
# renamed to *.md) lists only its new path, and a change to the app or the
# daemon would read as docs alone. The three dots diff from where the branch
# left the base, so what main did since doesn't count as the change's.
files=$(git diff --no-renames --name-only "${BASE:-}...${HEAD:-}" 2>/dev/null) ||
  everything "The diff of ${BASE:-?}...${HEAD:-?} couldn't be read: everything runs."
[ -n "$files" ] || everything "The diff of ${BASE:-?}...${HEAD:-?} is empty: everything runs."

app=false cli=false daemon=false
while IFS= read -r file; do
  case "$file" in
    .github/*) everything "A workflow or its script changed ($file): everything runs." ;;
    cli/*) cli=true ;;
    daemon/*) daemon=true ;;
    docs/* | priv/skills/* | *.md) ;;
    *) app=true ;;
  esac
done <<< "$files"

if [ "$app" = true ]; then
  decide true false "$cli" "$daemon" "The app changed: the suite runs."
fi

decide false true "$cli" "$daemon" "Only docs, skills, the CLI or the daemon changed: the repo checks run in the suite's place."
