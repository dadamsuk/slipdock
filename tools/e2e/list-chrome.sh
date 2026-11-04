#!/usr/bin/env bash
# End to end in a real browser: the board's list chrome recedes (#1710).
# A list header shows a heart only when the list is a favourite, and
# favouriting lives in the list's ⋯ menu; the footer's actions are labelled;
# "Add another list" is a ghost list as wide as a list, fully in view once
# the board is scrolled to its right edge, at 1280 and 1440.
#
#   tools/e2e/list-chrome.sh            # SHOTS=<dir> keeps screenshots
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
# Enough lists to scroll at 1440, one of them a favourite, one with a card.
COL=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Favourites}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"')
  for n <- ["Review", "Shipped", "Later"], do: {:ok, _} = Boards.create_column(board, %{"name" => n})
  board = Boards.get_board!('"$KB"')
  [first | _] = board.columns
  {:ok, _} = Boards.create_card(first, %{"title" => "Draft the brief"})
  {:ok, :added} = Favourites.toggle(user, :column, first.id)
  IO.puts("COL #{first.id}")
' | grep '^COL' | cut -d' ' -f2)
node tools/e2e/list-chrome.mjs "$LINK" "$BASE" "$KB" "$COL"
