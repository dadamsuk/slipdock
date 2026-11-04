#!/usr/bin/env bash
# End to end in a real browser: the phone shell at 390×844 (#1717). The
# board's toolbar is one row; the last thing on the board, Account and My
# work scrolls clear of the floating dock; the home list doesn't overflow
# sideways; Account → Profile stacks; the phone card's arrow has a name.
#
#   tools/e2e/phone-shell.sh            (SHOTS=dir to keep screenshots,
#                                        MEASURE=1 to print and not assert)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
# Enough cards that the board's first list, and My work, run past the dock.
mix run -e '
  alias Slipdock.{Accounts, Boards, Repo}
  {:ok, me} = Accounts.get_or_create_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first, second | _] = board.columns
  for n <- 1..14, do: {:ok, _} = Boards.create_card(first, %{"title" => "Card #{n}", "assignee_id" => me.id})
  {:ok, _} = Boards.create_card(second, %{"title" => "Over there"})
' > /dev/null
node tools/e2e/phone-shell.mjs "$LINK" "$BASE" "$KB"
