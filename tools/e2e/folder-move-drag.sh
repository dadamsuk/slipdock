#!/usr/bin/env bash
# End to end in a real browser (#746): drag a folder onto another board in a
# vault's tree, see what goes with it, confirm, and check it moved. LiveView
# tests can't drag; this drives the tree's pointer handling itself.
#
#   tools/e2e/folder-move-drag.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/folder-move-drag.mjs "$LINK" "$BASE" "$KB" "$HUNT"

# The folder and its page are on Journal Desk now, in the database itself.
mix run -e '
  folder = Slipdock.Repo.get!(Slipdock.Wiki.Folder, '"$SPECS"')
  page = Slipdock.Repo.get!(Slipdock.Wiki.Page, '"$PAGE"')
  unless folder.board_id == '"$HUNT"' and page.board_id == '"$HUNT"' and page.folder_id == folder.id,
    do: raise("not moved: #{inspect({folder.board_id, page.board_id, page.folder_id})}")
  IO.puts("ok: the folder and its page are on Journal Desk")
'
