#!/usr/bin/env bash
# End to end in a real browser (#1705): the vendored faces load and paint.
# On My work the page title is Sora 600; on the card back the code values
# (`field-mono`, `font-mono`) are JetBrains Mono; `document.fonts` has both
# faces loaded from /fonts; and Inter runs without cv11.
#
#   tools/e2e/fonts.sh   (SHOTS=dir keeps My work and the card back)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
CARD=$(mix run -e '
  board = Slipdock.Boards.get_board!('"$KB"') |> Slipdock.Repo.preload(:columns)
  [list | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Slipdock.Boards.create_card(list, %{"title" => "Fonts", "description" => "Code in `JetBrains Mono`."})
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)
node tools/e2e/fonts.mjs "$LINK" "$BASE" "$KB" "$CARD"
