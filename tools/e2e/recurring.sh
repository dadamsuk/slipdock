#!/usr/bin/env bash
# End to end in a real browser (W-1802, #1053): a browser in New York signs
# in and the account takes its timezone; a card is made recurring through
# the Repeat… form (a custom rule, previewed, saved, skipped, paused); the
# board shows ↻ on it; and Duplicate opens a copy.
#
#   tools/e2e/recurring.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

CARD=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [backlog | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(backlog, %{"title" => "Review invoices", "due_date" => "2027-01-12"})
  {:ok, _} = Boards.add_checklist_item(card, "Open the inbox")
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)

node tools/e2e/recurring.mjs "$LINK" "$BASE" "$KB" "$CARD" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

mix run -e '
  user = Slipdock.Accounts.get_user_by_email("e2e@example.com")
  if user.timezone != "America/New_York", do: raise("timezone is #{inspect(user.timezone)}")
  series = Slipdock.Recurrence.for_card(%{id: '"$CARD"'})
  if series.rule != "FREQ=MONTHLY;BYDAY=-1FR", do: raise("rule is #{series.rule}")
  IO.puts("ok: the database agrees (America/New_York, FREQ=MONTHLY;BYDAY=-1FR)")
'
