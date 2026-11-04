#!/usr/bin/env bash
# End to end in a real browser: every page and section with nothing in it
# shows the one empty state (#1715), an icon in a tinted square, a heading,
# a line of copy and, where there is a next step, its action.
#
#   tools/e2e/empty-state.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves a screenshot of each; BEFORE=1 only takes them (for the old pages).
source "$(dirname "$0")/lib.sh"
e2e_start
# The fixture page with no versions, and the board with nothing in its log.
SLUG=$(mix run -e '
  import Ecto.Query
  page = Slipdock.Repo.get!(Slipdock.Wiki.Page, '"$PAGE"')
  Slipdock.Repo.delete_all(from r in Slipdock.Wiki.Revision, where: r.page_id == ^page.id)
  Slipdock.Repo.delete_all(from a in Slipdock.Boards.Activity, where: a.board_id == '"$KB"')
  IO.puts("SLUG #{page.slug}")
' | grep '^SLUG' | cut -d' ' -f2)
node tools/e2e/empty-state.mjs "$LINK" "$BASE" "$KB" "$SLUG"
