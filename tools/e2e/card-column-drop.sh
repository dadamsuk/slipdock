#!/usr/bin/env bash
# End to end in a real browser (#827): drag a card onto another list's header,
# onto the empty board under a short list, and onto its own list's header,
# and check where each one landed. LiveView tests can't drag; this drives
# Sortable and the column drop in assets/js/card_drop.js.
#
#   tools/e2e/card-column-drop.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

# Backlog: Alpha, Bravo, Charlie. To Do: Delta, Echo. In Progress: Foxtrot.
mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [backlog, todo, doing | _] = Enum.sort_by(board.columns, & &1.position)
  for t <- ~w(Alpha Bravo Charlie), do: {:ok, _} = Boards.create_card(backlog, %{"title" => t})
  for t <- ~w(Delta Echo), do: {:ok, _} = Boards.create_card(todo, %{"title" => t})
  {:ok, _} = Boards.create_card(doing, %{"title" => "Foxtrot"})
' > /dev/null

node tools/e2e/card-column-drop.mjs "$LINK" "$BASE" "$KB"
