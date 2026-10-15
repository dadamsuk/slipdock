#!/usr/bin/env bash
# End to end in a real browser (#808, #810): "Also file in…" on a folder's
# ⋯ menu files Specs in Ideas as well; the placed row wears the link icon,
# opens to Specs' own contents, and opens and shuts apart from Specs at home.
#
#   tools/e2e/folder-also.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

IDEAS=$(mix run -e '
  kb = Slipdock.Boards.get_board!('"$KB"')
  {:ok, ideas} = Slipdock.Wiki.create_folder(kb, %{"name" => "Ideas"})
  IO.puts("IDEAS #{ideas.id}")
' | grep '^IDEAS' | cut -d' ' -f2)

node tools/e2e/folder-also.mjs "$LINK" "$BASE" "$KB" "$SPECS" "$IDEAS"

mix run -e '
  specs = Slipdock.Wiki.get_folder('"$SPECS"')
  [ideas] = Slipdock.Wiki.FolderPlacements.folders(specs)
  unless ideas.id == '"$IDEAS"', do: raise("not filed in Ideas: #{inspect(ideas)}")
  unless specs.parent_id == nil, do: raise("its home moved")
  IO.puts("ok: Specs is also filed in Ideas, and still at home at the top")
'
