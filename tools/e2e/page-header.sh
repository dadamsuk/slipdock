#!/usr/bin/env bash
# End to end in a real browser (#1714): one page header and three widths.
# At 1440 wide, each page checked has exactly one h1 with its title, sits in
# a frame of the width it says it is (narrow 672px, standard 1024px, full
# the window), and on home and Templates the header's buttons sit on the
# title's baseline.
#
#   tools/e2e/page-header.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots of home and Templates at 1440; with SHOTS_ONLY=1 it only
# takes them (for a before shot on a tree without the page header).
source "$(dirname "$0")/lib.sh"
e2e_start
node tools/e2e/page-header.mjs "$LINK" "$BASE" "$KB"
