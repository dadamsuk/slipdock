#!/usr/bin/env bash
# End to end in a real browser (#1728): the card back's section labels
# underline their key letter only while Alt is held, and the keys still jump;
# every section heading has an icon; subcards are added from one row with a
# list picker, and "Remove subcards" is in the section's ⋯ menu, asking
# first; a card with no attachments shows a one-line drop zone.
#
#   tools/e2e/card-sections.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

IDS=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, epic} = Boards.create_card(first, %{"title" => "Launch the new site", "description" => "The description."})
  {:ok, t} = Boards.find_template(nil, "Simple")
  {:ok, sub} = Boards.create_sub_board(epic, t)
  [sub_first | _] = sub |> Repo.preload(:columns) |> Map.get(:columns) |> Enum.sort_by(& &1.position)
  {:ok, _} = Boards.create_card(sub_first, %{"title" => "Write the copy"})
  IO.puts("IDS #{epic.id} #{sub.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/card-sections.mjs "$LINK" "$BASE" "$KB" $IDS "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
