#!/usr/bin/env bash
# End to end in a real browser (#3369): the board's Filter menu offers the
# tree's custom fields, each with a control suited to its kind. Picks a
# choice, types a number range and picks a from date through the app's date
# field, and checks which cards stay on the board each time.
#
#   tools/e2e/filter-fields.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  alias Slipdock.{Boards, Fields, Repo}
  Slipdock.Policy.as_system("an e2e seed", fn ->
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [todo | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, size} = Fields.create_field(board, %{"name" => "Size", "kind" => "select", "options" => ["Small", "Large"]})
  {:ok, effort} = Fields.create_field(board, %{"name" => "Effort", "kind" => "number"})
  {:ok, launch} = Fields.create_field(board, %{"name" => "Launch", "kind" => "date"})
  {:ok, small} = Boards.Cards.create_card(todo, %{"title" => "Tiny fix"})
  {:ok, large} = Boards.Cards.create_card(todo, %{"title" => "Big rebuild"})
  {:ok, _} = Boards.Cards.create_card(todo, %{"title" => "Unsized idea"})
  {:ok, _} = Fields.set_value(small, size, "small")
  {:ok, _} = Fields.set_value(small, effort, "1")
  {:ok, _} = Fields.set_value(small, launch, "2026-01-10")
  {:ok, _} = Fields.set_value(large, size, "large")
  {:ok, _} = Fields.set_value(large, effort, "8")
  {:ok, _} = Fields.set_value(large, launch, "2027-06-01")
  end)
' > /dev/null

node tools/e2e/filter-fields.mjs "$LINK" "$BASE" "$KB" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
