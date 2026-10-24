#!/usr/bin/env bash
# End to end in a real browser (#1230): the actions on a card's meta line
# ("Move to board…", the handoff link, "Ask questions") are drawn as buttons,
# with a border and a fill, and the plain text beside them is not.
#
#   tools/e2e/meta-actions.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

CARD=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(first, %{"title" => "A card", "description" => "The description."})
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)

node tools/e2e/meta-actions.mjs "$LINK" "$BASE" "$KB" "$CARD" "${SHOTS:-}" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
