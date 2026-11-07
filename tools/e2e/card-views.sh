#!/usr/bin/env bash
# End to end in a real browser (#2031): card views. The editor at
# /card-views hides an element at the board's level and the board follows;
# a list's level hides a section of the opened card for that list's cards;
# the Display menu's Show all brings every front element back, and is kept
# for the board after a reload.
#
#   tools/e2e/card-views.sh            (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
ids=$(mix run -e '
  alias Slipdock.Boards
  kb = Boards.get_board!('"$KB"')
  [todo, doing | _] = kb.columns
  {:ok, a} = Boards.create_card(todo, %{"title" => "Paint the fence", "priority" => "high", "description" => "Two coats."})
  {:ok, b} = Boards.create_card(doing, %{"title" => "Fix the gate", "priority" => "high", "description" => "New hinge."})
  IO.puts("IDS #{a.id} #{b.id} #{todo.id}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r A B TODO <<<"$ids"
node tools/e2e/card-views.mjs "$LINK" "$BASE" "$KB" "$A" "$B" "$TODO"
