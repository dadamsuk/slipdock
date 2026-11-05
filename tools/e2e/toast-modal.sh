#!/usr/bin/env bash
# End to end in a real browser: a toast that closes itself never closes the
# modal open under it (#1847). Adding a ready-made rule in Automations shows
# an info toast; 4.5s later the toast is gone and the modal is still open.
#
#   tools/e2e/toast-modal.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves a screenshot after the toast has gone.
source "$(dirname "$0")/lib.sh"
e2e_start
node tools/e2e/toast-modal.mjs "$LINK" "$BASE" "$KB"
