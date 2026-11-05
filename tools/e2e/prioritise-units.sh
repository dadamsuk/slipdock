#!/usr/bin/env bash
# End to end in a real browser (#1734): on the prioritise view each unit
# sits straight after its value (under 8px between them), every cell is
# centred on its row, and the numbers use Inter's tabular digits, not mono.
# The narrative view of the same board tells field changes without
# repeating the card's title, folded into one line.
#
#   tools/e2e/prioritise-units.sh    (SHOTS=dir keeps screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
CARD=$(mix run -e '
  board = Slipdock.Boards.get_board!('"$KB"') |> Slipdock.Repo.preload(:columns)
  [list | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, _} = Slipdock.Fields.install_preset(board, "rice")
  board = Slipdock.Boards.get_board!(board.id) |> Slipdock.Repo.preload(:fields)
  {:ok, card} = Slipdock.Boards.create_card(list, %{"title" => "Dark mode for the dashboard"})
  {:ok, _} = Slipdock.Boards.create_card(list, %{"title" => "Faster search"})
  values = %{"Reach" => "4000", "Impact" => "3", "Confidence" => "80", "Effort" => "3"}
  for f <- board.fields, v = values[f.name], do: {:ok, _} = Slipdock.Fields.set_value(Slipdock.Boards.get_card!(card.id), f, v)
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)
node tools/e2e/prioritise-units.mjs "$LINK" "$BASE" "$KB" "$CARD"
