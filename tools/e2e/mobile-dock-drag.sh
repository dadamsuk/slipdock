#!/usr/bin/env bash
# End to end in a real browser (#1130): on a phone, the floating navigation's
# button can be dragged out of the way. It settles against the nearer side,
# the row and the Menu open on screen from there, a tap still opens it, and
# the place it was put survives a reload and a navigation.
#
#   tools/e2e/mobile-dock-drag.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/mobile-dock-drag.mjs "$LINK" "$BASE" "$KB" "${SHOTS:-}" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
