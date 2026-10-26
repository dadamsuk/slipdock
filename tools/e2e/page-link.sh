#!/usr/bin/env bash
# End to end in a real browser: finding a page to reference (#1302). Typing
# [[ in a wiki page's editor and in a card's description opens the page
# picker, and taking a page writes its link; the card's "Attach a page
# already written…" box lists recent pages on focus and finds one by code.
#
#   tools/e2e/page-link.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

read -r CARD SPEC SPEC_CODE <<<"$(mix run -e '
  alias Slipdock.{Accounts, Boards, Wiki}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"')
  {:ok, card} = Boards.create_card(hd(board.columns), %{"title" => "Link card"})
  {:ok, spec} = Wiki.create_page(board, %{"title" => "Billing spec", "body" => "Rates.", "folder_id" => '"$SPECS"'}, user: user)
  IO.puts("IDS #{card.id} #{spec.id} #{spec.code}")
' | grep '^IDS' | cut -d' ' -f2-)"

node tools/e2e/page-link.mjs "$LINK" "$BASE" "$KB" "$CARD" "$SPEC" "$SPEC_CODE"

mix run -e '
  alias Slipdock.{Boards, Repo, Wiki}
  page = Repo.get!(Wiki.Page, '"$PAGE"')
  unless page.body =~ "See [[Billing spec]] now", do: raise("page body: #{inspect(page.body)}")
  card = Boards.get_card!('"$CARD"')
  unless card.description =~ "Per [[Acme call]]", do: raise("description: #{inspect(card.description)}")
  ids = card |> Wiki.pages_for_card() |> Enum.map(& &1.page.id)
  unless '"$SPEC"' in ids, do: raise("attached: #{inspect(ids)}")
  IO.puts("ok: [[ wrote the links, and the attach box attached by code")
'
