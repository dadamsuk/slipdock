#!/usr/bin/env bash
# End to end in a real browser (#757): KnowledgeBase kept inside GMinds is
# named on the vault's tile, not among the boards; its link on the tile opens
# the board, and the rest of the tile opens the vault.
#
#   tools/e2e/vault-inside.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  alias Slipdock.{Accounts, Vaults}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, vault} = Vaults.get_vault(user, "GMinds")
  {:ok, _} = Vaults.set_inside(vault, "/", true)
' > /dev/null

node tools/e2e/vault-inside.mjs "$LINK" "$BASE" "$KB"
