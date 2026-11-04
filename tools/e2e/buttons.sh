#!/usr/bin/env bash
# End to end in a real browser (#1703): the button hierarchy. A primary is
# the solid teal, a secondary the soft tint, a plain button a hairline
# surface, nothing carries btn-outline, and a button beside a field is
# btn-sm and shares its bottom edge (Account → Profile, Config → Email), in
# light and dark.
#
#   tools/e2e/buttons.sh            (SHOTS=dir keeps screenshots;
#                                    BEFORE=1 only takes them)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start
node tools/e2e/buttons.mjs "$LINK" "$BASE" "$KB"
