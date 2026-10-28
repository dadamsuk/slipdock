#!/usr/bin/env bash
# End to end in a real browser (#1485): the home page's Reorder mode. A
# press anywhere on a tile drags it (not only the handle), without opening
# the board; Done puts the links back.
#
#   tools/e2e/home-reorder.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/home-reorder.mjs "$LINK" "$BASE" "$KB" "$HUNT"

mix run -e '
  {:ok, user} = Slipdock.Accounts.get_or_create_user_by_email("e2e@example.com")
  first = user |> Slipdock.Access.list_boards() |> Slipdock.Boards.sort_boards("manual") |> hd()
  unless first.id == '"$HUNT"', do: raise("Journal Desk is not first: #{inspect(first.name)}")
  IO.puts("ok: the order from Reorder mode is saved")
'
