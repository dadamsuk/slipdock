#!/usr/bin/env bash
# End to end in a real browser (#1130): on a phone, the floating navigation's
# Menu opens on screen, nothing covers it, and its entries can be tapped —
# on the home page and on a board.
#
#   tools/e2e/mobile-menu.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/mobile-menu.mjs "$LINK" "$BASE" "$KB" "${SHOTS:-}" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
