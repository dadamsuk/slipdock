#!/usr/bin/env bash
# End to end (#1243's "done when"): copy a board's card address from the UI,
# send it a message the way the Cloudflare Worker does (raw MIME, signed),
# and the card appears on the board with its attachment; after New address,
# mail to the old one bounces and the new one works.
#
#   tools/e2e/inbound-email-to-card.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
export SLIPDOCK_INBOUND_DOMAIN="in.example.com" SLIPDOCK_INBOUND_SECRET="e2e-inbound-secret"
source "$(dirname "$0")/lib.sh"
e2e_start
trap 'kill $E2E_SERVER 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

node tools/e2e/inbound-email-to-card.mjs "$LINK" "$BASE" "$KB" "$SLIPDOCK_INBOUND_SECRET" "${SHOTS:-}" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
