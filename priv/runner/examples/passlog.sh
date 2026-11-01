#!/usr/bin/env bash
# A worked example of a pass log, for after-job-hook.sh to call: what a job's
# agent wrote, as a page for the card. Adapt it rather than run it as it is.
# Point the hook at it:
#
#   SLIPDOCK_HOOK_PASSLOG=/path/to/passlog.sh
#
#   passlog.sh TRANSCRIPT --exit N
#
# The page is `Pass <card> (<YYYY-MM-DD HH.MM>)`, written with `--card`, so it
# lands in the card's folder and shows on the card. That folder already says
# which card it is, so the title doesn't, and two passes on one card differ by
# their time. A pass that writes several files puts them in a folder
# `Pass <card>/` in the card's folder instead.
#
# The runner gives it SLIPDOCK_CARD, SLIPDOCK_CARD_URL and SLIPDOCK_JOB_ID.
# The board comes from the card's link, or SLIPDOCK_PASSLOG_BOARD. It reads the
# transcript with jq, and without jq keeps the transcript's last lines as they
# are. It needs a signed-in `slipdock` (SLIPDOCK_PASSLOG_CLI to name another).
#
# Fails with a message rather than writing a page it can't name: the hook logs
# that and carries on.
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8

CLI=${SLIPDOCK_PASSLOG_CLI:-slipdock}
TRANSCRIPT=${1:-}
RC=?
[ "${2:-}" = --exit ] && RC=${3:-?}
CARD=${SLIPDOCK_CARD:-}
URL=${SLIPDOCK_CARD_URL:-}

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "passlog: no transcript at '$TRANSCRIPT'" >&2
  exit 1
fi
if [ -z "$CARD" ]; then
  echo "passlog: SLIPDOCK_CARD is not set" >&2
  exit 1
fi

# …/boards/<board>/… in the card's link.
BOARD=${SLIPDOCK_PASSLOG_BOARD:-$(printf '%s' "$URL" | sed -n 's#.*/boards/\([^/]*\).*#\1#p')}
if [ -z "$BOARD" ]; then
  echo "passlog: no board in '$URL': set SLIPDOCK_PASSLOG_BOARD" >&2
  exit 1
fi

# The text of everything the agent said, oldest first.
agent_text() {
  if command -v jq >/dev/null 2>&1; then
    jq -r 'select(.type == "assistant") | .message.content[]?
           | select(.type == "text") | .text + "\n"' "$1" 2>/dev/null
  else
    tail -n 50 "$1"
  fi
}

BODY=$(mktemp) || exit 1
trap 'rm -f "$BODY"' EXIT
{
  echo "Pass on #$CARD, job #${SLIPDOCK_JOB_ID:-?}, exit $RC."
  echo
  agent_text "$TRANSCRIPT"
} >"$BODY"

exec "$CLI" page new "$BOARD" "Pass $CARD ($(date '+%Y-%m-%d %H.%M'))" \
  --file "$BODY" --card "$CARD" --summary "Full output of the pass on #$CARD"
