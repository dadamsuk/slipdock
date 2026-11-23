#!/usr/bin/env bash
# End to end in a real browser (#3665): the columns of the table, the outline
# and Prioritise are reordered by dragging them in the Display menu, hidden by
# unticking them, and resized by dragging a heading's right edge; a
# double-click puts a width back, and a reload keeps what was chosen.
#
#   tools/e2e/view-columns.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  alias Slipdock.{Boards, Fields, Repo}
  Slipdock.Policy.as_system("an e2e seed", fn ->
    board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
    [todo | _] = Enum.sort_by(board.columns, & &1.position)
    {:ok, epic} = Boards.Cards.create_card(todo, %{"title" => "An epic with a fairly long title", "priority" => "high"})
    {:ok, _} = Boards.Cards.create_card(todo, %{"title" => "Second card", "priority" => "low"})
    {:ok, _} = Fields.install_preset(board, "rice")
    IO.puts("seeded #{epic.id}")
  end)
' | grep -q '^seeded'

node tools/e2e/view-columns.mjs "$LINK" "$BASE" "$KB" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
