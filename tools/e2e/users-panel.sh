#!/usr/bin/env bash
# End to end in a real browser: the Users page's read-only table and the
# person panel (#1739). The rows hold nothing but a Manage link; a row opens
# the panel at ?user=<id>, and every control that was on the row works from
# there: the paid-up date, the item limit, Unlimited, Support, Disable and
# Enable through the app's confirm box, and Close down to the typed address.
# Your own panel has no danger zone, and Escape closes the panel.
#
#   tools/e2e/users-panel.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots; BEFORE=1 only takes them (for the old page).
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1 || true
e2e_start
PERSON=$(mix run -e '
  {:ok, user} = Slipdock.Accounts.get_or_create_user_by_email("e2e-person@example.com")
  IO.puts("ID #{user.id}")
' | grep '^ID' | cut -d' ' -f2)
node tools/e2e/users-panel.mjs "$LINK" "$BASE" "$PERSON" e2e-person@example.com
