#!/usr/bin/env bash
# End to end in a real browser (#1704): every checkbox is a 16px square with
# a 4px radius, a toggle that is on is filled with the primary, a radio is
# round, and the three look different, in light and dark.
#
#   tools/e2e/controls.sh            (SHOTS=dir keeps screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
CARD=$(mix run -e '
  board = Slipdock.Boards.get_board!('"$KB"') |> Slipdock.Repo.preload(:columns)
  [list | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Slipdock.Boards.create_card(list, %{"title" => "Controls"})
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)
node tools/e2e/controls.mjs "$LINK" "$BASE" "$KB" "$CARD"
