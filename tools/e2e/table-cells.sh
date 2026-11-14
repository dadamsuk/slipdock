#!/usr/bin/env bash
# End to end in a real browser (#1731): the table reads as a table. At rest
# no select draws its caret and no empty due date says "Add date"; hovering
# a row or tabbing into a cell turns it back into its control. Each row has
# one due value, rows with long tag lists are as tall as the rest, the
# Assignee column is there by default, and Tab walks the editable cells.
#
#   tools/e2e/table-cells.sh         (SHOTS=dir keeps screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

IDS=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [_backlog, todo | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  today = Date.utc_today()

  tags =
    for {name, color} <- [{"frontend", "sky"}, {"needs-design-review", "violet"},
                          {"customer-reported", "red"}, {"performance", "amber"},
                          {"accessibility", "lime"}, {"documentation", "teal"}] do
      {:ok, tag} = Boards.Tags.create_tag(board, %{"name" => name, "color" => color})
      tag
    end

  {:ok, many} =
    Boards.create_card(todo, %{"title" => "Many tags", "priority" => "high",
      "due_date" => Date.to_iso8601(Date.add(today, -3))})
  {:ok, many} = Boards.update_card(many, %{"assignee_id" => user.id})
  for tag <- tags, do: Boards.toggle_card_tag(many, tag)

  {:ok, soon} = Boards.create_card(todo, %{"title" => "Due soon",
    "due_date" => Date.to_iso8601(Date.add(today, 1))})
  Boards.toggle_card_tag(soon, hd(tags))

  {:ok, bare} = Boards.create_card(todo, %{"title" => "Nothing set"})
  IO.puts("IDS #{many.id} #{soon.id} #{bare.id} #{todo.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/table-cells.mjs "$LINK" "$BASE" "$KB" $IDS || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
