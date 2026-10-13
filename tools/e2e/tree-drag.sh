#!/usr/bin/env bash
# End to end in a real browser (#749): without Organise mode, drag a file
# and a page about a board's tree with the mouse, check a drop opens
# nothing, and that a plain click still opens a page. LiveView tests can't
# drag; this drives the tree's pointer handling itself.
#
#   tools/e2e/tree-drag.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

FILE=$(mix run -e '
  path = Path.join(System.tmp_dir!(), "e2e-cat-#{System.os_time()}")
  File.write!(path, "PNGBYTES")
  kb = Slipdock.Boards.get_board!('"$KB"')
  {:ok, file} = Slipdock.Wiki.Files.create(kb, %{name: "cat.png"}, path)
  IO.puts("ID #{file.id}")
' | grep '^ID' | cut -d' ' -f2)

node tools/e2e/tree-drag.mjs "$LINK" "$BASE" "$KB"

mix run -e '
  file = Slipdock.Repo.get!(Slipdock.Wiki.WikiFile, '"$FILE"')
  page = Slipdock.Repo.get!(Slipdock.Wiki.Page, '"$PAGE"')
  unless file.folder_id == '"$SPECS"', do: raise("file not moved: #{inspect(file.folder_id)}")
  unless page.folder_id == nil, do: raise("page not moved: #{inspect(page.folder_id)}")
  IO.puts("ok: cat.png is in Specs, and Acme call at the top")
'
