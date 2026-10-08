#!/usr/bin/env bash
# A worked example of runner hooks: what one Slipdock server's own runner
# (pool loop, working its To Do list) runs before and after every job.
# Adapt it rather than run it as it is: the notifier and what to record are
# yours to choose. Point the runner's hooks at it, in the wizard or its config:
#
#   before_job() { /path/to/after-job-hook.sh before; }
#   after_job()  { /path/to/after-job-hook.sh after; }
#
# The runner gives it SLIPDOCK_JOB_ID, SLIPDOCK_JOB_KIND, SLIPDOCK_CARD,
# SLIPDOCK_CARD_URL and, after a job, SLIPDOCK_STATUS (done, failed,
# cancelled or timeout) and SLIPDOCK_EXIT.
#
# Before a job: marks when it started, so the transcript can be found after.
# After a job:
#   * Pass log: the job's Claude Code transcript (the newest one written since
#     the job started that mentions the card's URL) goes to $PASSLOG, which
#     can turn it into a wiki page pinned to the card.
#   * A job that timed out or failed sends an alert through $NOTIFY.
#
# What it leaves to the server: putting back a card the job left in
# progress (the rule's requeue_stuck) and alerting on that (a job_finished
# rule). It never moves or flags cards itself.
#
# It never fails the runner: every step is best effort and it exits 0. Its
# output goes into the job's log, so it writes its own log instead. Settings
# come from the environment, so the tests can point them elsewhere.
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8
LOG=${SLIPDOCK_HOOK_LOG:-$HOME/.local/state/slipdock-runner/hook.log}
STATE=${SLIPDOCK_HOOK_STATE:-$HOME/.local/state/slipdock-runner}
# Where Claude Code keeps this project's transcripts: ~/.claude/projects/
# and the job's working directory with every / and . as a -.
TRANSCRIPTS=${SLIPDOCK_HOOK_TRANSCRIPTS:-$HOME/.claude/projects/-home-me-src-app}
# PASSLOG TRANSCRIPT --exit N — empty to skip. One server's turns the
# transcript into a wiki page with `slipdock page new … --card`.
PASSLOG=${SLIPDOCK_HOOK_PASSLOG:-}
# NOTIFY TITLE MESSAGE — empty to only log. For example:
#   ntfy:     curl -fsS -H "Title: $1" -d "$2" https://ntfy.sh/your-topic
#   PushOver: curl -fsS --form-string token=… --form-string user=… \
#               --form-string title="$1" --form-string message="$2" \
#               https://api.pushover.net/1/messages.json
#   Slack:    curl -fsS -H 'Content-Type: application/json' \
#               -d "{\"text\": \"$1: $2\"}" https://hooks.slack.com/services/…
NOTIFY=${SLIPDOCK_HOOK_NOTIFY:-}

JOB=${SLIPDOCK_JOB_ID:-}
CARD=${SLIPDOCK_CARD:-}
STATUS=${SLIPDOCK_STATUS:-}
RC=${SLIPDOCK_EXIT:-}

mkdir -p "$STATE" "$(dirname "$LOG")" 2>/dev/null
log() { echo "=== $(date -Is) $*" >>"$LOG" 2>/dev/null; }
# limit SECONDS COMMAND… — the runner reports the job only once this hook
# returns, so nothing in it may hang. (macOS has no `timeout`: run it plain.)
limit() {
  local s=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi
}
# notify TITLE MESSAGE — never fails the caller, and never waits long.
notify() {
  [ -n "$NOTIFY" ] || return 0
  limit 20 $NOTIFY "Slipdock runner · $1" "$2" >>"$LOG" 2>&1 || log "notify failed: $1"
}

if [ -z "$JOB" ] || [ -z "$CARD" ]; then
  log "hook ${1:-?} called without SLIPDOCK_JOB_ID/SLIPDOCK_CARD; nothing done"
  exit 0
fi
MARK="$STATE/job-$JOB.start"

before() {
  touch "$MARK"
  log "job #$JOB started on card #$CARD"
}

# The job's transcript: newest .jsonl written since the job started that
# mentions the card's URL (or, without a URL, any written since the start).
transcript() {
  [ -f "$MARK" ] || return 1
  local f
  find "$TRANSCRIPTS" -maxdepth 1 -name '*.jsonl' -newer "$MARK" -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | cut -d' ' -f2- | while IFS= read -r f; do
      if [ -z "${SLIPDOCK_CARD_URL:-}" ] || grep -qF "$SLIPDOCK_CARD_URL" "$f"; then
        echo "$f"
        break
      fi
    done
}

passlog() {
  [ -n "$PASSLOG" ] || return 0
  local t
  t=$(transcript)
  if [ -n "$t" ]; then
    limit 45 $PASSLOG "$t" --exit "${RC:-255}" >>"$LOG" 2>&1 || log "passlog failed for $t"
  else
    log "job #$JOB: no transcript found for card #$CARD"
  fi
}

after() {
  local why
  case "$STATUS" in
    timeout) why="stopped by the runner's timeout" ;;
    cancelled) why="cancelled" ;;
    *) why="$STATUS, exit ${RC:-?}" ;;
  esac
  log "job #$JOB on card #$CARD finished ($why)"
  passlog
  case "$STATUS" in
    timeout) notify "job timed out" "Job #$JOB on #$CARD was $why. ${SLIPDOCK_CARD_URL:-}" ;;
    failed) notify "job failed" "Job #$JOB on #$CARD ended ($why). ${SLIPDOCK_CARD_URL:-}" ;;
  esac
  rm -f "$MARK"
}

case "${1:-}" in
  before) before ;;
  after) after ;;
  *) echo "usage: $0 before|after" >&2; exit 2 ;;
esac
exit 0
