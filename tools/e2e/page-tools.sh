#!/usr/bin/env bash
# End to end in a real browser (#1539): the AI tools beside a wiki page answer
# while reading, and while editing Add to the page puts the answer in the
# Markdown editor, where it saves with the page. Also the phone's sheet.
#
#   tools/e2e/page-tools.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
AI_PORT="${AI_PORT:-4199}"
export SLIPDOCK_AI_BASE_URL="http://127.0.0.1:$AI_PORT/v1" SLIPDOCK_AI_MODEL="fake/model"
export FAKE_AI_REPLY='Sharper words from the model.'
node "$(dirname "$0")/fake-ai.mjs" "$AI_PORT" &
FAKE_AI=$!
source "$(dirname "$0")/lib.sh"
e2e_start
trap 'kill $E2E_SERVER $FAKE_AI 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

node tools/e2e/page-tools.mjs "$LINK" "$BASE" "$KB" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
