#!/usr/bin/env bash
# End to end in a real browser (#1663): a wiki page's actions sit above its
# folder and title, and the Page details button on that row opens the details
# just beneath it. The panel stays open across the page's own updates (a
# favourite) and starts closed again on another page.
#
#   tools/e2e/page-details.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

# A second page, to check another page starts with its details closed.
mix run -e '
  kb = Slipdock.Boards.get_board!('"$KB"')
  {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "Second page", "body" => "Elsewhere."})
' > /dev/null

node tools/e2e/page-details.mjs "$LINK" "$BASE" "$KB" "$PAGE" ||
  { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
