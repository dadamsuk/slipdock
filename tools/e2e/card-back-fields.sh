#!/usr/bin/env bash
# End to end in a real browser (#1672): every text box, select and editor on
# the card back is drawn as one field (the `field` classes in app.css): one
# border, radius, font family and focus ring, at one of two sizes, in light
# and dark. Opens a card with every section filled, the description editor,
# a comment and the Repeat… form, and compares the fields' computed styles.
#
#   tools/e2e/card-back-fields.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

IDS=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Repo}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [todo | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(todo, %{"title" => "Plan the launch", "description" => "The **plan**, with a list:\n\n- one\n- two"})
  {:ok, card} = Boards.update_card(card, %{"bar" => "Shipped and announced", "paths" => ["lib/launch/**"], "due_date" => Date.utc_today()})
  {:ok, other} = Boards.create_card(todo, %{"title" => "Write the post"})
  {:ok, _} = Boards.create_card(todo, %{"title" => "A subcard", "parent_id" => card.id})
  {:ok, _} = Boards.add_checklist_item(card, "Book the room")
  {:ok, _} = Boards.add_comment(card, "Looks good to me.", by: user)
  {:ok, _} = Boards.add_card_url(card, %{"url" => "https://example.com/spec", "title" => "Spec"})
  {:ok, _} = Boards.add_link(card, other, "relates")
  IO.puts("IDS #{card.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/card-back-fields.mjs "$LINK" "$BASE" "$KB" "$IDS" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
