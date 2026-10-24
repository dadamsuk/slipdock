#!/usr/bin/env bash
# End to end in a real browser (#1245): the board menu's "Email to this
# board" shows your card address, Copy puts it on the clipboard, and New
# address (after the app's own confirm) replaces it; the Account tab shows
# the personal Quick Add address the same way.
#
#   tools/e2e/inbound-addresses.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
export SLIPDOCK_INBOUND_DOMAIN="in.example.com" SLIPDOCK_INBOUND_SECRET="e2e-inbound-secret"
source "$(dirname "$0")/lib.sh"
e2e_start
trap 'kill $E2E_SERVER 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

node tools/e2e/inbound-addresses.mjs "$LINK" "$BASE" "$KB" "${SHOTS:-}" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
