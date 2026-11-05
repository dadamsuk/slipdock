#!/usr/bin/env bash
# End to end in a real browser (#1721): the date fields that replaced the
# raw date inputs still save. Schedules an undated card from the timeline's
# tray, and sets then clears a due date in the table, typing each date into
# the field the way a person would; the database has each value, and the
# table shows one due value per row.
#
#   tools/e2e/date-sweep.sh            (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1 || true
e2e_start
ids=$(mix run -e '
  alias Slipdock.Boards
  kb = Boards.get_board!('"$KB"')
  {:ok, loose} = Boards.create_card(hd(kb.columns), %{"title" => "Loose end"})
  {:ok, row} = Boards.create_card(hd(kb.columns), %{"title" => "Table row", "due_date" => "2030-01-15"})
  IO.puts("IDS #{loose.id} #{row.id}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r LOOSE ROW <<<"$ids"
node tools/e2e/date-sweep.mjs "$LINK" "$BASE" "$KB" "$LOOSE" "$ROW"
