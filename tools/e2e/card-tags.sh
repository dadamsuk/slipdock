#!/usr/bin/env bash
# End to end in a real browser (#1727): a card's flags and tags are the ones
# applied, as chips, then "+ Add", which opens a checklist. On a board with
# 40 tags the section stays one row. The picker narrows as you type, makes a
# new tag on Enter, and stays beside its button while you tick; the panel's
# keys (f, t) open the pickers.
#
#   tools/e2e/card-tags.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

IDS=$(mix run -e '
  alias Slipdock.{Boards, Palette, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  colours = Palette.names()
  tags =
    for i <- 1..40 do
      {:ok, t} = Boards.create_tag(board, %{"name" => "Tag #{String.pad_leading(to_string(i), 2, "0")}", "color" => Enum.at(colours, rem(i, length(colours)))})
      t
    end
  {:ok, card} = Boards.create_card(first, %{"title" => "Plan the launch", "description" => "The description."})
  {:ok, _} = Boards.toggle_card_tag(card, Enum.at(tags, 2))
  {:ok, _} = Boards.toggle_card_tag(Boards.get_card!(card.id), Enum.at(tags, 11))
  {:ok, _} = Boards.toggle_flag(Boards.get_card!(card.id), "flagged")
  IO.puts("IDS #{card.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/card-tags.mjs "$LINK" "$BASE" "$KB" $IDS "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
