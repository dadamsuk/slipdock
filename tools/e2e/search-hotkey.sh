#!/usr/bin/env bash
# End to end in a real browser (#1533): Shift-Alt-S goes to Search everything
# from any page, even mid-sentence, with the cursor in the box; on the search
# page it only puts the cursor back, and from Ask it switches to Search.
#
#   tools/e2e/search-hotkey.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
AI_PORT="${AI_PORT:-4198}"
export SLIPDOCK_AI_BASE_URL="http://127.0.0.1:$AI_PORT/v1" SLIPDOCK_AI_MODEL="fake/model"
node "$(dirname "$0")/fake-ai.mjs" "$AI_PORT" &
FAKE_AI=$!
source "$(dirname "$0")/lib.sh"
e2e_start
trap 'kill $E2E_SERVER $FAKE_AI 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

node tools/e2e/search-hotkey.mjs "$LINK" "$BASE" "$KB" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
