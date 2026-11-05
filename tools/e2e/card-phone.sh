#!/usr/bin/env bash
# End to end in a real browser (#1729): on a phone the card back's first
# screen holds its list, assignee, due date and priority (a summary under the
# title that opens onto the property rows), and they can be changed from
# there. On a desktop the properties stay in the sidebar.
#
#   tools/e2e/card-phone.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

IDS=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Repo}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  long = Enum.map_join(1..12, "\n\n", &"Paragraph #{&1}: the plan, at length, so the description is long.")
  {:ok, card} = Boards.create_card(first, %{"title" => "Plan the launch of the new site", "description" => long})
  {:ok, _} = Boards.update_card(card, %{"priority" => "high", "due_date" => Date.add(Date.utc_today(), 9), "assignee_id" => user.id})
  {:ok, _} = Boards.add_checklist_item(card, "Book the room")
  IO.puts("IDS #{card.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/card-phone.mjs "$LINK" "$BASE" "$KB" $IDS "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
