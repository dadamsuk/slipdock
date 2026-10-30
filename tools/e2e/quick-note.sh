#!/usr/bin/env bash
# End to end in a real browser (#1538): the header button and Shift-Alt-N open
# the quick note overlay from any page, even mid-sentence, Ctrl-Enter saves it
# and the overlay says where the note went.
#
#   tools/e2e/quick-note.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
AI_PORT="${AI_PORT:-4198}"
export SLIPDOCK_AI_BASE_URL="http://127.0.0.1:$AI_PORT/v1" SLIPDOCK_AI_MODEL="fake/model"
export FAKE_AI_REPLY='{"title": "Printers banners", "folder": "Specs"}'
node "$(dirname "$0")/fake-ai.mjs" "$AI_PORT" &
FAKE_AI=$!
source "$(dirname "$0")/lib.sh"
e2e_start
trap 'kill $E2E_SERVER $FAKE_AI 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

node tools/e2e/quick-note.mjs "$LINK" "$BASE" "$KB" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
