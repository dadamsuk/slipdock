#!/usr/bin/env bash
# End to end in a real browser: Help's How work flows page (#1885). Signed
# out, at 1440 and at 390, in the light and the dark theme: the agents index,
# the Runners topic and the hub link to it; the seven stages in order; the
# diagram's nodes in a column with the person's ones ringed and their words
# readable against the ring's tint; and no horizontal scroll anywhere.
#
#   tools/e2e/help-flow.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots.
source "$(dirname "$0")/lib.sh"
e2e_start
node tools/e2e/help-flow.mjs "$BASE"
