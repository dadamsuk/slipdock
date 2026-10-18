#!/usr/bin/env bash
# End to end in a real browser (#1098): Delete… on a page's menu in the
# wiki's tree, by right-click and by the ⋯ button. It asks, saying the page
# under it is kept; Cancel keeps it; Delete for good takes it, leaves the
# wiki if that page was open, and puts its child at the top.
#
#   tools/e2e/page-delete.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

read -r SCRATCH KEPT SLUG <<<"$(mix run -e '
  alias Slipdock.{Accounts, Boards, Wiki}
  user = Accounts.get_user_by_email("e2e@example.com")
  kb = Boards.get_board!('"$KB"')
  {:ok, scratch} = Wiki.create_page(kb, %{"title" => "Scratch"}, user: user)
  {:ok, kept} = Wiki.create_page(kb, %{"title" => "Kept", "parent_id" => scratch.id}, user: user)
  IO.puts("IDS #{scratch.id} #{kept.id} #{scratch.slug}")
' | grep '^IDS' | cut -d' ' -f2-)"

node tools/e2e/page-delete.mjs "$LINK" "$BASE" "$KB" "$SCRATCH" "$KEPT" "$SLUG" "$PAGE" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

mix run -e '
  alias Slipdock.Wiki
  if Wiki.get_page('"$SCRATCH"'), do: raise("Scratch is still there")
  if Wiki.get_page('"$PAGE"'), do: raise("Acme call is still there")
  %{parent_id: nil} = Wiki.get_page('"$KEPT"')
  IO.puts("ok: the database agrees (both deleted, Kept at the top)")
'
