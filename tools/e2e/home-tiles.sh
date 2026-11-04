#!/usr/bin/env bash
# End to end in a real browser (#1716): board handles out of the way, Share
# in view. Home tiles draw a thin colour strip and no code or key chips (the
# code is in the name's tooltip and shows on hover); the board header has no
# code chip either; the toolbar's Share button opens the settings panel on
# its Sharing tab.
#
#   tools/e2e/home-tiles.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots of the home page and the board's header.
source "$(dirname "$0")/lib.sh"
e2e_start
node tools/e2e/home-tiles.mjs "$LINK" "$BASE" "$KB"
