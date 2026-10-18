#!/usr/bin/env bash
# End to end in a real browser: the home page lists the vault among
# the boards, as a card like theirs; dragging it in front of a board keeps the
# new order; New vault looks like New board and makes a vault.
#
#   tools/e2e/home-vaults.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/home-vaults.mjs "$LINK" "$BASE" "$KB" "$HUNT"

mix run -e '
  {:ok, user} = Slipdock.Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, vault} = Slipdock.Vaults.get_vault(user, "Notes")
  unless vault.position == 0, do: raise("the dragged vault is not first: #{inspect(vault.position)}")
  {:ok, _} = Slipdock.Vaults.get_vault(user, "Fresh")
  IO.puts("ok: the order and the new vault are saved")
'
