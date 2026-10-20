#!/usr/bin/env bash
# End to end in a real browser (#1169): a wiki page whose Markdown has long
# lines (a long paragraph, a long unbroken URL, long inline code, a wide code
# block and table) must wrap within the viewport, read and edited, on a
# desktop and a phone width. Code blocks and tables scroll inside their own
# box; nothing makes the page itself scroll sideways.
#
#   tools/e2e/wiki-wrap.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

SLUG=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Wiki}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"')
  words = String.duplicate("a long line of ordinary words that keeps going ", 40)
  url = "https://example.com/" <> String.duplicate("averyveryverylongpathsegment", 12)
  code = String.duplicate("unbroken_identifier_", 20)
  body = """
  #{words}

  See #{url} for more.

  Inline `#{code}` code.

  ```
  #{String.duplicate("x = 1; ", 60)}
  ```

      An indented line, which Markdown reads as code: #{words}

  | a | b |
  |---|---|
  | #{code} | #{words} |
  | #{url} | short |

  - #{url}
  > #{url}
  """
  {:ok, page} = Wiki.create_page(board, %{"title" => "Long lines", "body" => body}, user: user)
  IO.puts("SLUG #{page.slug}")
' | grep '^SLUG' | cut -d' ' -f2-)

node tools/e2e/wiki-wrap.mjs "$LINK" "$BASE" "$KB" "$SLUG" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
