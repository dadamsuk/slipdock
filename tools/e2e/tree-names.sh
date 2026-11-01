#!/usr/bin/env bash
# End to end in a real browser (#1594): a card's long title in the wiki tree
# is shortened by CSS alone, with the whole name in the DOM and on hover, and
# the header's button swaps it for the short name, which stays set.
#
#   tools/e2e/tree-names.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

# LiveViewTest has no layout, so this has to be built CSS.
mix tailwind slipdock > /dev/null 2>&1

ids=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Repo, Wiki}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"')
  title = "Agent supervision 5/9: parked jobs must be released on timeout, and everybody told about it"
  {:ok, card} = Boards.create_card(hd(board.columns), %{"title" => title})
  {:ok, card} = Boards.update_card(card, %{"short_name" => "Parked jobs"})
  {:ok, page} = Wiki.create_page_from_card(card, user: user, title: "Write up")
  folder = Wiki.get_folder(Repo.get!(Wiki.Page, page.id).folder_id)
  IO.puts("IDS #{folder.parent_id} #{folder.id}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r CARDS FOLDER <<<"$ids"

node tools/e2e/tree-names.mjs "$LINK" "$BASE" "$KB" "$CARDS" "$FOLDER"

mix run -e '
  {:ok, user} = Slipdock.Accounts.get_or_create_user_by_email("e2e@example.com")
  unless user.tree_names == "short", do: raise("not kept: #{user.tree_names}")
  IO.puts("ok: the choice is saved on the person")
'
