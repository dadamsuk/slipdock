#!/usr/bin/env bash
# End to end in a real browser (#1532): an image pasted into a new page before
# it has a title or a save, typing that survives a reload, the page resumed
# from the list of unsaved work, and Save turning the held image into an
# attachment.
#
#   tools/e2e/wiki-autosave.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/wiki-autosave.mjs "$LINK" "$BASE" "$KB" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

mix run -e '
  import Ecto.Query
  alias Slipdock.{Boards, Repo, Wiki}
  page = Repo.one!(from p in Wiki.Page, where: p.title == "Pasted first")
  [attachment] = Wiki.attachments(page)
  if page.body =~ "autosave-files" or not (page.body =~ Boards.attachment_url(attachment)),
    do: raise("body is #{page.body}")
  if Repo.aggregate(Wiki.Autosave, :count) != 0, do: raise("an auto-save was left behind")
  IO.puts("ok: the database agrees (one attachment, its link in the body, nothing held)")
'
