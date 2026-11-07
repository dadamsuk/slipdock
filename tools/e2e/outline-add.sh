#!/usr/bin/env bash
# End to end in a real browser: the outline's add icon and pages (#2024).
# No "Add a subcard" row under open cards; the + beside a card opens one,
# focused, and Enter adds the subcard under it; 260 top-level cards (261 rows)
# make two pages of at most 250 rows, and Next starts the second at its top;
# rows are under 36px (37 before).
#
#   tools/e2e/outline-add.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
mix run -e '
  alias Slipdock.Boards
  board = Boards.get_board!('"$KB"')
  col = hd(board.columns)
  {:ok, t} = Boards.find_template(nil, "Simple")
  epic = Enum.reduce(1..260, nil, fn n, acc ->
    {:ok, c} = Boards.create_card(col, %{"title" => "Card #{String.pad_leading(to_string(n), 3, "0")}"})
    acc || c
  end)
  {:ok, sub} = Boards.create_sub_board(epic, t)
  {:ok, _} = Boards.create_card(hd(Boards.get_board!(sub.id).columns), %{"title" => "Existing child"})
' > /dev/null
node tools/e2e/outline-add.mjs "$LINK" "$BASE" "$KB"
