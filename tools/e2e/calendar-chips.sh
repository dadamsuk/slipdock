#!/usr/bin/env bash
# End to end in a real browser (#1733): on the demo board's calendar at a
# 1440px-wide window, every month chip shows at least 20 characters of its
# title before any decoration, the full title is in its tooltip, the
# decorations come back on a wider chip, and no unlabelled arrow is left.
#
#   tools/e2e/calendar-chips.sh            (SHOTS=dir keeps screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
BOARD=$(mix run -e '
  alias Slipdock.{Accounts, Boards}
  {:ok, launch} = Slipdock.Demo.build(force: true)
  {:ok, owner} = Accounts.get_or_create_user_by_email(Slipdock.Demo.owner_email())
  {:ok, me} = Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, _} = Slipdock.Access.grant(launch, me, "write", owner)
  board = Boards.get_board!(launch.id) |> Slipdock.Repo.preload(:tags)
  [_, todo | _] = board.columns
  today = Date.utc_today()
  # The worst case: a long title carrying every decoration a chip can have.
  {:ok, card} =
    Boards.create_card(todo, %{
      "title" => "Reconcile quarterly invoices with the ledger export",
      "priority" => "critical",
      "flags" => ["flagged", "blocked"],
      "start_date" => Date.add(today, -1),
      "due_date" => Date.add(today, 1)
    })
  for tag <- Enum.take(board.tags, 3), do: Boards.toggle_card_tag(card, tag)
  IO.puts("BOARD #{board.id}")
' | grep '^BOARD' | cut -d' ' -f2)
node tools/e2e/calendar-chips.mjs "$LINK" "$BASE" "$BOARD"
