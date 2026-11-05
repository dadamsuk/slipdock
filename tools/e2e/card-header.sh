#!/usr/bin/env bash
# End to end in a real browser (#1725): the top of the card back. Under the
# title a quiet breadcrumb (Board › List · #id · created), with no bordered
# buttons; the actions (Move, the handoff, Ask, ⋯) in a toolbar on the close
# button's row; an epic with one "Open board"; and on a phone the toolbar
# still one row that leaves the title alone.
#
#   tools/e2e/card-header.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

IDS=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(first, %{"title" => "Plan the launch", "description" => "The description."})
  {:ok, epic} = Boards.create_card(first, %{"title" => "Launch the new site"})
  {:ok, t} = Boards.find_template(nil, "Simple")
  {:ok, sub} = Boards.create_sub_board(epic, t)
  [sub_first | _] = sub |> Repo.preload(:columns) |> Map.get(:columns) |> Enum.sort_by(& &1.position)
  {:ok, _} = Boards.create_card(sub_first, %{"title" => "Write the copy"})
  {:ok, _} = Boards.create_card(sub_first, %{"title" => "Pick the photos"})
  IO.puts("IDS #{card.id} #{epic.id} #{sub.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/card-header.mjs "$LINK" "$BASE" "$KB" $IDS "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
