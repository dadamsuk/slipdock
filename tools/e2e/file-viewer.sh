#!/usr/bin/env bash
# End to end in a real browser (#762, #768): a wiki's files open from the
# tree, or a page's [[link]], in a panel on the right of the wiki — a CSV
# as a table, JSON as a folding tree, a PNG and an SVG drawn, a PDF in the
# browser's PDF viewer, HTML in a sandbox whose scripts never run. LiveView tests can't tell
# whether an image or a frame actually loads; this does.
#
#   tools/e2e/file-viewer.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  kb = Slipdock.Boards.get_board!('"$KB"')
  png = Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
  pdf = """
  %PDF-1.4
  1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
  2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
  3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj
  trailer<</Root 1 0 R>>
  %%EOF
  """
  files = [
    {"people.csv", "name,age\nAda,36\n\"Lovelace, A\",37\n"},
    {"config.json", ~s({"name": "x", "deep": {"inner": [1, 2]}})},
    {"dot.png", png},
    {"logo.svg", ~S|<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="red"/><script>alert(1)</script></svg>|},
    {"Spec.pdf", pdf},
    {"Report.html", ~S|<h1 id="t">Quarterly</h1><script>alert(1)</script><img src="x" onerror="alert(2)">|}
  ]
  for {name, bytes} <- files do
    path = Path.join(System.tmp_dir!(), "e2e-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    {:ok, _} = Slipdock.Wiki.Files.create(kb, %{name: name}, path)
  end
  {:ok, _} = Slipdock.Wiki.create_page(kb, %{"title" => "Files home", "body" => "The data: [[people.csv]]"}, user: Slipdock.Repo.preload(kb, :owner).owner)
'

node tools/e2e/file-viewer.mjs "$LINK" "$BASE" "$KB"
