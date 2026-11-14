#!/usr/bin/env bash
# End to end in a real browser: a card's title (#1707) is 13px or larger on
# a comfortable card and 12px on a compact one, and starts at the same x as
# its tag row, with and without a hover, on the board, in swimlanes and on a
# sub-board. The complete toggle shows on hover, keyboard focus and touch,
# and showing it never moves the title.
#
#   tools/e2e/card-title.sh            (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
ids=$(mix run -e '
  alias Slipdock.Boards
  kb = Boards.get_board!('"$KB"')
  [todo | _] = kb.columns
  {:ok, tag} = Boards.Tags.create_tag(kb, %{"name" => "Design", "color" => "sky"})
  {:ok, card} = Boards.create_card(todo, %{"title" => "Paint the shed before the rain comes", "due_date" => "2030-01-15"})
  {:ok, _} = Boards.set_card_tags(card, [tag])
  {:ok, t} = Boards.find_template(nil, "Simple")
  {:ok, sub} = Boards.create_sub_board(card, t, code: "subttl")
  sub = Boards.get_board!(sub.id)
  {:ok, child} = Boards.create_card(hd(sub.columns), %{"title" => "Sand the boards"})
  stag = Boards.Tags.create_tag(sub, %{"name" => "Prep", "color" => "lime"}) |> elem(1)
  {:ok, _} = Boards.set_card_tags(child, [stag])
  IO.puts("IDS #{card.id} #{sub.id} #{child.id}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r CARD SUB CHILD <<<"$ids"
node tools/e2e/card-title.mjs "$LINK" "$BASE" "$KB" "$CARD" "$SUB" "$CHILD"
