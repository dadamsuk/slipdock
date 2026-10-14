#!/usr/bin/env bash
# End to end in a real browser: the Markdown editor (CodeMirror with
# atomic-editor's live preview) over a wiki page's body, a card's
# description and its comment box — that it renders lines away from the
# caret, that what is typed reaches the server, and that the hooks round the
# textarea (Escape, @mentions, pasting an image) still work through it.
#
#   tools/e2e/markdown-editor.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

CARD=$(mix run -e '
  board = Slipdock.Boards.get_board!('"$KB"')
  {:ok, card} = Slipdock.Boards.create_card(hd(board.columns), %{"title" => "Editor card"})
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)

node tools/e2e/markdown-editor.mjs "$LINK" "$BASE" "$KB" "$CARD"

mix run -e '
  alias Slipdock.{Boards, Repo, Wiki}
  page = Repo.get!(Wiki.Page, '"$PAGE"')
  unless page.body =~ "# Plan **now**" and page.body =~ "/attachments/" and not (page.body =~ "Uploading"),
    do: raise("page not saved: #{inspect(page.body)}")
  card = Boards.get_card!('"$CARD"')
  unless card.description == "**Bold** move", do: raise("description: #{inspect(card.description)}")
  unless Enum.any?(card.comments, &(&1.body =~ ~r/^Ping @\S+ ok$/)),
    do: raise("comments: #{inspect(Enum.map(card.comments, & &1.body))}")
  IO.puts("ok: the page, the description and the comment were all saved as typed")
'
