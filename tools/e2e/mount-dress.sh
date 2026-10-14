#!/usr/bin/env bash
# End to end in a real browser (#797): a board mounted in a vault (Journal
# Desk at /Plans) has a ⋯ menu in the tree, on the board's wiki and in the
# vault's view, its page count stays clear of it, and its Icon and colour…
# dresses the row.
#
#   tools/e2e/mount-dress.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/mount-dress.mjs "$LINK" "$BASE" "$KB"

mix run -e '
  {:ok, m} = Slipdock.Vaults.find_mapping(Slipdock.Repo.get_by!(Slipdock.Vaults.Vault, name: "Notes"), "/Plans")
  unless m.icon == "briefcase", do: raise("not saved: #{inspect({m.icon, m.color})}")
  IO.puts("ok: the mount wears what was picked")
'
