#!/usr/bin/env bash
# End to end in a real browser (#1702): the brand palette is what the page
# paints. In light and dark, base-100, base-content and the primary are the
# decision's values (W-2307), the theme-color meta follows the theme when it
# is switched, and the loading bar is drawn in the primary.
#
#   tools/e2e/brand-tokens.sh   (SHOTS=dir keeps the home, board, card back
#                                and Account; BEFORE_CSS=file also shoots them
#                                with that stylesheet, for a before/after)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
CARD=$(mix run -e '
  board = Slipdock.Boards.get_board!('"$KB"') |> Slipdock.Repo.preload(:columns)
  [list | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Slipdock.Boards.create_card(list, %{"title" => "Brand tokens", "description" => "The palette, in `app.css`."})
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)
node tools/e2e/brand-tokens.mjs "$LINK" "$BASE" "$KB" "$CARD"
