#!/usr/bin/env bash
# End to end in a real browser: a board's Display options are remembered in
# the browser (#1879). Choose compact cards, leave for the wiki, come back to
# the board's bare address and they are back; another browser starts from the
# defaults; going back to comfortable is remembered too. On a phone the
# Display and View menus open wholly on screen (#1926).
#
#   tools/e2e/display-prefs.sh            # SHOTS=<dir> keeps screenshots
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
mix run -e '
  alias Slipdock.Boards
  board = Boards.get_board!('"$KB"')
  {:ok, _} = Boards.create_card(hd(board.columns), %{"title" => "Draft the brief"})
' > /dev/null
node tools/e2e/display-prefs.mjs "$LINK" "$BASE" "$KB"
