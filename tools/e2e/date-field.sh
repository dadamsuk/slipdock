#!/usr/bin/env bash
# End to end in a real browser: the date field (#1720) on the card back.
# Clicking the date and pressing Enter open the browser's picker
# (showPicker); typing a date sets it, typing another changes it, the ×
# clears it, and each one is stored: the words survive a reload and another
# edit's re-render, and the database has the value. Where showPicker is
# missing, the plain date input shows instead.
#
#   tools/e2e/date-field.sh            (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1 || true
e2e_start
CARD=$(mix run -e '
  alias Slipdock.Boards
  kb = Boards.get_board!('"$KB"')
  {:ok, card} = Boards.create_card(hd(kb.columns), %{"title" => "Book the venue"})
  IO.puts("ID #{card.id}")
' | grep '^ID' | cut -d' ' -f2)
export CARD
node tools/e2e/date-field.mjs "$LINK" "$BASE" "$KB" "$CARD"
