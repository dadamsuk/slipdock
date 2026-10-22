#!/usr/bin/env bash
# End to end in a real browser (#1203): on a page's editor, picking an icon
# and then a colour keeps the icon, and saving keeps both.
#
#   tools/e2e/page-dress.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/page-dress.mjs "$LINK" "$BASE" "$KB"

mix run -e '
  page = Slipdock.Repo.get!(Slipdock.Wiki.Page, '"$PAGE"')
  unless {page.icon, page.color} == {"briefcase", "amber"}, do: raise("not saved: #{inspect({page.icon, page.color})}")
  IO.puts("ok: the page wears what was picked")
'
