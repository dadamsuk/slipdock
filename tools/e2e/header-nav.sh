#!/usr/bin/env bash
# End to end in a real browser: the header from lg up (#1713). Boards, My
# work and Wiki are links with the current one marked; search is a field;
# quick add holds Quick note; the heart sits right of quick add; the bell
# counts what waits on you; every icon button names itself and its key. On
# a tablet the old icons come back.
#
#   tools/e2e/header-nav.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
# Something waiting on the signed-in person, and an alert, so the bell's
# badge is the sum of both.
mix run -e '
  alias Slipdock.{Accounts, Actor, Boards, Repo}
  {:ok, me} = Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, asker} = Accounts.get_or_create_user_by_email("asker@example.com")
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  {:ok, card} = Boards.create_card(hd(board.columns), %{"title" => "Which region?"})
  actor = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: asker.id}
  {:ok, _} = Boards.open_wait(card, actor, %{"needs" => "Which region?", "on_user_id" => me.id})
  {:ok, _} = Slipdock.Automations.raise_alert(%{"board_id" => board.id, "title" => "Stuck"})
' > /dev/null
node tools/e2e/header-nav.mjs "$LINK" "$BASE" "$KB"
