#!/usr/bin/env bash
# End to end in a real browser (#752): the home page's vault tile, the vault's
# tree, a page at its vault path, and editing it.
#
#   tools/e2e/vault-view.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/vault-view.mjs "$LINK" "$BASE"

mix run -e '
  page = Slipdock.Repo.get!(Slipdock.Wiki.Page, '"$PAGE"')
  unless page.body =~ "Edited in the vault view", do: raise("not saved: #{inspect(page.body)}")
  IO.puts("ok: the edit is saved")
'
