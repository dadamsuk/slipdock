#!/usr/bin/env bash
# End to end in a real browser (#1745): a history row opens onto the lines
# that version changed, and the tree shows a long folder/page pair whole at
# its default width, each row with its full name in `title`.
#
#   tools/e2e/wiki-history.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

SLUG=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Wiki}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  kb = Boards.get_board!('"$KB"')
  apart = [user: user, new_revision: true]
  {:ok, page} = Wiki.create_page(kb, %{"title" => "Launch plan", "body" => "Intro.\n\nShip on Friday.\n\nOld note.\n"}, user: user)
  {:ok, page} = Wiki.update_page(page, %{"body" => "Intro.\n\nAdded paragraph.\n\nShip on Friday.\n\nOld note.\n"}, apart)
  {:ok, page} = Wiki.update_page(page, %{"body" => "Intro.\n\nAdded paragraph.\n\nShip on Friday.\n"}, apart)
  {:ok, page} = Wiki.update_page(page, %{"body" => "Intro.\n\nAdded paragraph.\n\nShip on Monday.\n"}, apart)
  # A long folder and the page of the same name inside it.
  {:ok, folder} = Wiki.create_folder(kb, %{"name" => "Self-serve trial sign-up flow"})
  {:ok, _} = Wiki.create_page(kb, %{"title" => "Self-serve trial sign-up flow", "body" => "x", "folder_id" => folder.id}, user: user)
  IO.puts(page.slug)
' | tail -1)

node tools/e2e/wiki-history.mjs "$LINK" "$BASE" "$KB" "$SLUG" ||
  { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
