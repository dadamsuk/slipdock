#!/usr/bin/env bash
# End to end in a real browser: every toolbar search box shows its
# magnifying glass on top of the field (#1695), with the field look (8px
# radius, 28px high), and on a phone the board's box folds behind a glass
# until tapped.
#
#   tools/e2e/search-icon.sh            (SHOTS=<dir> to save screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
node tools/e2e/search-icon.mjs "$LINK" "$BASE" "$KB"
