#!/usr/bin/env bash
# End to end in a real browser: the header's bell sits on the same middle
# line as the icons beside it (#1675), rather than a few pixels below them.
#
#   tools/e2e/header-bell.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
# Two alerts, so the bell wears its count as it does in the card's screenshot.
mix run -e '
  for t <- ["Overdue", "Stuck"], do: {:ok, _} = Slipdock.Automations.raise_alert(%{"board_id" => '"$KB"', "title" => t})
' > /dev/null
node tools/e2e/header-bell.mjs "$LINK" "$BASE" "$KB"
