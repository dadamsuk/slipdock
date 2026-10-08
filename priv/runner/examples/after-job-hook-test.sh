#!/usr/bin/env bash
# Tests for after-job-hook.sh: runs it with fake notify and passlog commands
# and a folder of fake transcripts.
#   bash after-job-hook-test.sh [path/to/after-job-hook.sh]
set -u
HOOK=${1:-$(dirname "$0")/after-job-hook.sh}
HOOK=$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")
URL=https://slipdock.example/boards/3/cards/
pass=0 fail=0

ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; echo "       ($2)"; fi; }

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/transcripts" "$T/state"
  : >"$T/calls"; : >"$T/notes"
  cat >"$T/bin/notify" <<'EOS'
#!/usr/bin/env bash
echo "$1 :: $2" >>"$FAKE/notes"
EOS
  cat >"$T/bin/passlog" <<'EOS'
#!/usr/bin/env bash
echo "passlog $*" >>"$FAKE/calls"
EOS
  chmod +x "$T/bin/"*
}

# hook PHASE CARD JOB [STATUS EXIT]
hook() {
  FAKE=$T SLIPDOCK_HOOK_LOG=$T/log SLIPDOCK_HOOK_STATE=$T/state \
  SLIPDOCK_HOOK_TRANSCRIPTS=$T/transcripts \
  SLIPDOCK_HOOK_PASSLOG=${PASSLOG-$T/bin/passlog} SLIPDOCK_HOOK_NOTIFY=${NOTIFY-$T/bin/notify} \
  SLIPDOCK_JOB_ID=$3 SLIPDOCK_CARD=$2 SLIPDOCK_CARD_URL="$URL$2" \
  SLIPDOCK_STATUS=${4:-} SLIPDOCK_EXIT=${5:-} \
    bash "$HOOK" "$1"
}
# a transcript written during the job, mentioning card URL $2
transcript() { sleep 0.05; echo "{\"prompt\":\"work $URL$2 now\"}" >"$T/transcripts/$1.jsonl"; }

echo "a clean job: pass log, no alert"
setup
hook before 7 41
check "start marker written"        '[ -e "$T/state/job-41.start" ]'
transcript sess-a 7
hook after 7 41 done 0; rc=$?
check "exits 0"                     '[ $rc -eq 0 ]'
check "passlog on the transcript"   'grep -q "^passlog $T/transcripts/sess-a.jsonl --exit 0" "$T/calls"'
check "no alert"                    '[ ! -s "$T/notes" ]'
check "start marker cleared"        '[ ! -e "$T/state/job-41.start" ]'
check "logged"                      'grep -q "job #41 on card #7 finished (done, exit 0)" "$T/log"'

echo "the pass log picks this card's transcript, not a newer one for another card"
setup
hook before 7 42
transcript mine 7
transcript other 99
hook after 7 42 done 0
check "this card's transcript"      'grep -q "^passlog $T/transcripts/mine.jsonl" "$T/calls"'
check "only one passlog"            '[ "$(grep -c ^passlog "$T/calls")" = 1 ]'

echo "transcripts older than the job are ignored"
setup
echo "{\"x\":\"$URL""7\"}" >"$T/transcripts/old.jsonl"
touch -d '1 hour ago' "$T/transcripts/old.jsonl" 2>/dev/null || touch -t 202001010000 "$T/transcripts/old.jsonl"
hook before 7 43
hook after 7 43 done 0
check "no passlog"                  '! grep -q ^passlog "$T/calls"'
check "logged no transcript"        'grep -q "job #43: no transcript found for card #7" "$T/log"'

echo "no start marker: no pass log"
setup
transcript sess 7
hook after 7 44 done 0
check "no passlog"                  '! grep -q ^passlog "$T/calls"'

echo "a failed job: alert with the exit code and the card's link"
setup
hook before 7 45; transcript s 7
hook after 7 45 failed 1
check "failure alert"               'grep -q "job failed :: Job #45 on #7 ended (failed, exit 1). ${URL}7" "$T/notes"'
check "passlog with exit 1"         'grep -q "^passlog .*--exit 1" "$T/calls"'

echo "a timeout: alert"
setup
hook after 7 48 timeout 124
check "timeout alert"               'grep -q "job timed out :: Job #48 on #7 was stopped by the runner.s timeout" "$T/notes"'

echo "cancelled: no alert"
setup
hook after 7 49 cancelled 130
check "no alert"                    '[ ! -s "$T/notes" ]'

echo "no notifier or pass log configured: only the log"
setup
NOTIFY= PASSLOG= hook after 7 50 timeout 124; rc=$?
check "exits 0"                     '[ $rc -eq 0 ]'
check "nothing called"              '[ ! -s "$T/calls" ] && [ ! -s "$T/notes" ]'

echo "never touches the board"
check "no slipdock command in it"   '! grep -Eq "^[^#]*slipdock (move|flag|comment|edit|done)" "$HOOK"'

echo "a failing notifier never fails the hook"
setup
printf '#!/bin/sh\nexit 1\n' >"$T/bin/notify"
hook after 7 52 timeout 124; rc=$?
check "exits 0"                     '[ $rc -eq 0 ]'
check "logged"                      'grep -q "notify failed: job timed out" "$T/log"'

echo "a failing pass log never fails the hook"
setup
printf '#!/bin/sh\nexit 3\n' >"$T/bin/passlog"
hook before 7 53; transcript s 7
hook after 7 53 done 0; rc=$?
check "exits 0"                     '[ $rc -eq 0 ]'
check "logged"                      'grep -q "passlog failed for" "$T/log"'

echo "missing job env: does nothing"
setup
FAKE=$T SLIPDOCK_HOOK_LOG=$T/log SLIPDOCK_HOOK_STATE=$T/state SLIPDOCK_HOOK_NOTIFY=$T/bin/notify \
  SLIPDOCK_JOB_ID= SLIPDOCK_CARD= bash "$HOOK" after; rc=$?
check "exits 0"                     '[ $rc -eq 0 ]'
check "no alert"                    '[ ! -s "$T/notes" ]'
check "logged"                      'grep -q "without SLIPDOCK_JOB_ID" "$T/log"'

echo "bad phase: usage"
setup
hook bogus 7 54 2>/dev/null; rc=$?
check "exits 2"                     '[ $rc -eq 2 ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
