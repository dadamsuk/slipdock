#!/usr/bin/env bash
# End to end in a real browser (#758): a board's wiki is the vault from where
# the board is mounted down. Keystone's tree has Plans (Journal Desk's wiki)
# among its folders, a Journal Desk page opened from it keeps Keystone's
# tree and breadcrumbs, and Journal Desk's own wiki shows only its part.
#
#   tools/e2e/vault-chroot.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  alias Slipdock.{Accounts, Boards, Wiki}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  kb = Boards.get_board!('"$KB"')
  hunt = Boards.get_board!('"$HUNT"')
  # Sorted by name, so Archive (made after Specs) comes first.
  kb |> Ecto.Changeset.change(wiki_sort: "name") |> Slipdock.Repo.update!()
  {:ok, _} = Wiki.create_folder(kb, %{"name" => "Archive"})
  {:ok, prep} = Wiki.create_folder(hunt, %{"name" => "Prep"})
  {:ok, _} = Wiki.create_page(hunt, %{"title" => "Intake Questions", "body" => "Why us?", "folder_id" => prep.id}, user: user)
' > /dev/null

node tools/e2e/vault-chroot.mjs "$LINK" "$BASE" "$KB" "$HUNT"
