#!/usr/bin/env bash
# End to end in a real browser (#1108): a card with a very long title must not
# widen the table's Title column past its share; the title truncates and the
# other columns keep their room.
#
#   tools/e2e/table-title.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

ID=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [_backlog, todo | _] = Enum.sort_by(board.columns, & &1.position)
  title = String.duplicate("a very long card title that goes on ", 5) |> String.trim()
  {:ok, a} = Boards.create_card(todo, %{"title" => title})
  {:ok, _} = Boards.create_card(todo, %{"title" => "Short"})
  IO.puts("ID #{a.id}")
' | grep '^ID' | cut -d' ' -f2-)

node tools/e2e/table-title.mjs "$LINK" "$BASE" "$KB" "$ID" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
