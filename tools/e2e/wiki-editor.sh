#!/usr/bin/env bash
# End to end in a real browser (#1744): the wiki editor opens as one pane at
# the whole width. The Preview pane is a toggle the browser remembers;
# encryption waits in the editor's ⋯ menu on an ordinary page and stands in
# the row on an encrypted one; Save is the one primary button.
#
#   tools/e2e/wiki-editor.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  kb = Slipdock.Boards.get_board!('"$KB"')
  {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "Plain notes", "body" => "## Notes\n\nNothing secret here."})
  {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "Vaulted", "body" => "Door: 🔐β 💡usual💡U2FsdGVkX19abcdefghijklmnop= 🔐"})
' > /dev/null

node tools/e2e/wiki-editor.mjs "$LINK" "$BASE" "$KB" ||
  { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
