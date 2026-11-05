#!/usr/bin/env bash
# End to end in a real browser (#1726): the card back's sidebar is a list of
# properties, a label on the left and the value on the right, with no List
# select and no Completed switch (the meta line and the title's check do
# those). Precision hides at "day" until More is opened. Each property still
# saves.
#
#   tools/e2e/card-properties.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

IDS=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Repo}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first, second | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(first, %{"title" => "Plan the launch"})
  {:ok, card} = Boards.update_card(card, %{"priority" => "high", "due_date" => Date.add(Date.utc_today(), 7), "start_date" => Date.utc_today(), "percent_complete" => 40, "assignee_id" => user.id})
  IO.puts("IDS #{card.id} #{second.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/card-properties.mjs "$LINK" "$BASE" "$KB" $IDS "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
