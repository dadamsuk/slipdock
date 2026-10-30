#!/usr/bin/env bash
# End to end in a real browser (#1534): the shared-page editor, as somebody
# who cannot read the board. An image pasted into it, typing that survives a
# reload, the edit picked up from Unsaved work on Shared with me, and Save
# writing the page.
#
#   tools/e2e/shared-autosave.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

SHARED=$(mix run -e '
  alias Slipdock.{Access, Accounts, Boards, Wiki}
  {:ok, me} = Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, owner} = Accounts.get_or_create_user_by_email("owner@example.com")
  {:ok, board} = Boards.create_board(%{"name" => "Theirs", "code" => "theirs"}, owner_id: owner.id)
  {:ok, page} = Wiki.create_page(board, %{"title" => "Their plan", "body" => "As it stands."}, user: owner)
  {:ok, _} = Access.grant(page, me, "write", owner)
  IO.puts("ID #{page.id}")
' | grep '^ID' | cut -d' ' -f2)

node tools/e2e/shared-autosave.mjs "$LINK" "$BASE" "$SHARED" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

mix run -e '
  import Ecto.Query
  alias Slipdock.{Boards, Repo, Wiki}
  page = Repo.one!(from p in Wiki.Page, where: p.title == "Their plan")
  [attachment] = Wiki.attachments(page)
  if not (page.body =~ "Typed in the browser" and page.body =~ Boards.attachment_url(attachment)),
    do: raise("body is #{page.body}")
  if Repo.aggregate(Wiki.Autosave, :count) != 0, do: raise("an auto-save was left behind")
  IO.puts("ok: the database agrees (text and image saved, nothing left behind)")
'
