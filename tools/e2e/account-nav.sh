#!/usr/bin/env bash
# End to end in a real browser: Account's sections in the settings layout
# (#1737). At 1280 and 1440 every section is in the side nav with no
# sideways scroll; at 390 the picker reaches every one; the current section
# is marked and named over its content, and each link is a fresh mount.
#
#   tools/e2e/account-nav.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots; BEFORE=1 only takes them (for the old tab strip).
# Inbound mail and voiceprints are on, so all eight sections are listed.
export SLIPDOCK_INBOUND_DOMAIN=in.example.com
export SLIPDOCK_INBOUND_SECRET=e2e-secret
source "$(dirname "$0")/lib.sh"
e2e_start
mix run -e '
  {:ok, _} =
    Slipdock.Settings.update(%{
      "meetings_enabled" => true,
      "meetings_voiceprints" => true,
      "meetings_voiceprint_url" => "http://voice.example.com/embed"
    })
' > /dev/null
# The server caches the settings row, so it starts again to read them.
kill "$E2E_SERVER"
wait "$E2E_SERVER" 2>/dev/null || true
mix phx.server > "$LOG" 2>&1 &
E2E_SERVER=$!
for _ in $(seq 1 60); do
  curl -sf -o /dev/null "$BASE/login" && break
  sleep 2
done
node tools/e2e/account-nav.mjs "$LINK" "$BASE"
