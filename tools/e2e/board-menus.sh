#!/usr/bin/env bash
# End to end in a real browser (#1133): a board's own buttons — the AI chat
# and its … menu — sit in the board's toolbar, right of Views, and not in the
# app's header row; the … menu opens there whole, in the board view and in
# the table view, on a laptop and on a tablet.
#
#   tools/e2e/board-menus.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
AI_PORT="${AI_PORT:-4198}"
export SLIPDOCK_AI_BASE_URL="http://127.0.0.1:$AI_PORT/v1" SLIPDOCK_AI_MODEL="fake/model" FAKE_AI_LOG="$(mktemp)"
node "$(dirname "$0")/fake-ai.mjs" "$AI_PORT" &
FAKE_AI=$!
source "$(dirname "$0")/lib.sh"
e2e_start
trap 'kill $E2E_SERVER $FAKE_AI 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

node tools/e2e/board-menus.mjs "$LINK" "$BASE" "$KB" "${SHOTS:-}" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
