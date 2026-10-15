#!/usr/bin/env bash
# End to end in two real browsers (#824): two people with the same drawing
# open, one its owner and one with write access to the board, each draw a
# rectangle; each sees the other's arrive without reloading, the drawing saves
# itself (there is no Save button), and both shapes are there after a reload
# and in the saved note.
#
#   PORT=4099 tools/e2e/drawing-live.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

DRAWING=$(mix run -e '
  alias Slipdock.{Access, Accounts, Boards}
  {:ok, owner} = Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, friend} = Accounts.get_or_create_user_by_email("friend@example.com")
  board = Boards.get_board!('"$KB"')
  {:ok, _} = Access.grant(board, friend, "write", owner)
  {:ok, page} = Slipdock.Wiki.Drawings.create(board, nil, user: owner)
  IO.puts("ID #{page.id}")
' | grep '^ID' | cut -d' ' -f2)

FRIEND_LINK=$(mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:slipdock)
  {:ok, path} = Slipdock.Accounts.write_agentic_login("friend@example.com", &"'"$BASE"'/login/#{&1}")
  IO.write(File.read!(path))
  File.rm(path)
' | tail -1)

node tools/e2e/drawing-live.mjs "$LINK" "$FRIEND_LINK" "$BASE" "$DRAWING"

mix run -e '
  page = Slipdock.Repo.get!(Slipdock.Wiki.Page, '"$DRAWING"')
  {:ok, %{scene: scene}} = Slipdock.Wiki.Excalidraw.parse_markdown(page.body)
  live = Enum.reject(scene["elements"], & &1["isDeleted"])
  unless length(live) == 2, do: raise("the saved note holds #{length(live)} shapes, not 2")
  IO.puts("ok: the saved note holds both rectangles")
'
