#!/usr/bin/env bash
# End to end in a real browser (#814): Share… on a page's ⋯ menu shares it
# with another person, can edit; the tree marks it shared, the tree's own
# Share… opens the same dialog, and taking the share back clears both.
#
#   PORT=4099 tools/e2e/wiki-share.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '{:ok, _} = Slipdock.Accounts.get_or_create_user_by_email("friend@example.com")' > /dev/null

node tools/e2e/wiki-share.mjs "$LINK" "$BASE" "$KB" "$PAGE"

mix run -e '
  page = Slipdock.Wiki.get_page!('"$PAGE"')
  unless Slipdock.Access.list_grants(page) == [], do: raise("the share was not taken back")
  IO.puts("ok: the page is shared with nobody again")
'
