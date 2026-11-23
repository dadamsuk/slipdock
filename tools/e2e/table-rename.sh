#!/usr/bin/env bash
# End to end in a real browser (#3670): a card is renamed from the table's
# Title cell (the pencil, then Enter or leaving the box) and recoloured from
# its Color cell, without opening the card.
#
#   tools/e2e/table-rename.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

ID=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  Slipdock.Policy.as_system("an e2e seed", fn ->
    board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
    [todo | _] = Enum.sort_by(board.columns, & &1.position)
    {:ok, a} = Boards.Cards.create_card(todo, %{"title" => "Before"})
    IO.puts("ID #{a.id}")
  end)
' | grep '^ID' | cut -d' ' -f2-)

node tools/e2e/table-rename.mjs "$LINK" "$BASE" "$KB" "$ID" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
