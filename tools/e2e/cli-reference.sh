#!/usr/bin/env bash
# End to end in a real browser: Help's CLI command reference (#1884). Signed
# out, at 1440 and at 390: every group of the CLI's help in order with a
# contents link that scrolls to it, the filter narrowing to a command and
# back, no horizontal scroll on the page, and long lines wrapping or
# scrolling inside their own block. The CLI topic page and the agents index
# link to it.
#
#   tools/e2e/cli-reference.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots.
source "$(dirname "$0")/lib.sh"
e2e_start
node tools/e2e/cli-reference.mjs "$BASE"
