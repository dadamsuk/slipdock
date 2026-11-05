#!/usr/bin/env bash
# End to end in a real browser (#1743): a wiki page reads in one column.
# Paragraphs, lists, headings and their rules, and the "Cards this is about"
# footer all end at the same right edge, about 68ch; a wide table keeps to it. The
# action row is one button style with Edit emphasised, the page code copies
# from its button, and "Attach a card…" is a `field`.
#
#   tools/e2e/wiki-measure.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  kb = Slipdock.Boards.get_board!('"$KB"')
  para = String.duplicate("A sentence long enough to wrap across the reading column several times over. ", 6)
  cells = Enum.map_join(1..12, " | ", &"Column #{&1} heading")
  row = Enum.map_join(1..12, " | ", fn _ -> "value" end)
  body = """
  #{para}

  ## A heading with a rule

  - #{para}
  - A short item

  ### A smaller heading

  | #{cells} |
  |#{String.duplicate("---|", 12)}
  | #{row} |

  #{para}
  """
  {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "Measured page", "body" => body})
' > /dev/null

node tools/e2e/wiki-measure.mjs "$LINK" "$BASE" "$KB" ||
  { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
