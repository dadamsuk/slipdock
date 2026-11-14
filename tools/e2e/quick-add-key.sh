#!/usr/bin/env bash
# End to end in a real browser (#2871): the header's quick add has one key,
# q. On a board, c is the board's own key and leaves quick add shut; with the
# wiki's tree holding the keyboard (data-own-keys), neither key opens it.
#
#   PORT=4147 tools/e2e/quick-add-key.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/quick-add-key.mjs "$LINK" "$BASE" "$KB" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
