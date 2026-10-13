#!/usr/bin/env bash
# End to end in a real browser (#760): rest the mouse on a page in a
# board's tree and its preview shows beside the tree; moving to a folder
# puts it away; Space shows it from the keyboard. LiveView tests can't
# hover; this drives the tree's own pointer handling.
#
#   tools/e2e/tree-preview.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/tree-preview.mjs "$LINK" "$BASE" "$KB"
