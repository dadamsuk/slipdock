#!/usr/bin/env bash
# A rehearsal of #819 with the real CLI against a throwaway server and a
# throwaway vault — never a real one. The owner (e2e@example.com) shares
# Specs with a friend, who files it in their own vault's Inbox; their
# `slipdock sync` gets stubs, not content; an edit to a stub is put back;
# revoking takes the stubs away. Nothing of Acme call's text ever lands.
#
#   PORT=4099 tools/e2e/sync-stubs.sh
source "$(dirname "$0")/lib.sh"
e2e_start

FRIEND=$(mix run -e '
  alias Slipdock.{Access, Accounts, Boards, Vaults, Wiki}
  {:ok, owner} = Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, friend} = Accounts.get_or_create_user_by_email("friend@example.com")
  {:ok, mine} = Boards.create_board(%{"name" => "Friend board", "code" => "friende2e"}, owner_id: friend.id)
  {:ok, inbox} = Wiki.create_folder(mine, %{"name" => "Inbox"})
  {:ok, vault} = Vaults.create_vault(friend, %{"name" => "Friend vault"})
  {:ok, _} = Vaults.add_mapping(vault, friend, %{path: "/", board: Boards.get_board!(mine.id)})
  specs = Wiki.get_folder('"$SPECS"')
  {:ok, grant} = Access.grant(specs, friend, "read", owner)
  {:ok, _} = Wiki.FolderPlacements.add(specs, inbox, friend)
  {token, _} = Accounts.create_api_token(friend, "rehearsal")
  IO.puts("FRIEND #{vault.id} #{grant.id} #{token}")
' | grep '^FRIEND' | cut -d' ' -f2-)
read -r VAULT GRANT TOKEN <<<"$FRIEND"

(cd cli && MIX_ENV=prod mix escript.build --quiet >/dev/null)
CLI="$PWD/cli/slipdock"
MIRROR=$(mktemp -d)
CLI_HOME=$(mktemp -d)
# The CLI alone gets a home of its own and the friend's token; mix keeps ours.
cli() { HOME="$CLI_HOME" SLIPDOCK_URL="$BASE" SLIPDOCK_TOKEN="$TOKEN" "$CLI" "$@"; }

cli sync init "$MIRROR" --vault "$VAULT" > /dev/null
STUB="$MIRROR/Inbox/Specs/Acme call.md"
test -f "$STUB" || { echo "FAIL: no stub at Inbox/Specs/Acme call.md"; ls -R "$MIRROR"; exit 1; }
grep -q "/shared/pages/$PAGE)" "$STUB" || { echo "FAIL: stub isn't a link: $(cat "$STUB")"; exit 1; }
if grep -rq "Went well" "$MIRROR"; then echo "FAIL: shared content reached the mirror"; exit 1; fi
echo "ok: the shared folder synced as a folder of stubs, links only"

echo "my own words" > "$STUB"
OUT=$(cli sync "$MIRROR")
grep -q "/shared/pages/$PAGE)" "$STUB" || { echo "FAIL: the edited stub wasn't put back"; exit 1; }
echo "$OUT" | grep -q "↺ Inbox/Specs/Acme call.md" || { echo "FAIL: the sync log didn't say why: $OUT"; exit 1; }
mix run -e '
  unless Slipdock.Wiki.get_page!('"$PAGE"').body == "Went well.", do: raise("the stub edit reached the page")
' > /dev/null
echo "ok: an edit to a stub was put back, the log said why, and the page is untouched"

mix run -e 'Slipdock.Access.revoke(Slipdock.Access.get_grant!('"$GRANT"'))' > /dev/null
cli sync "$MIRROR" > /dev/null
test -e "$STUB" && { echo "FAIL: the stub outlived the share"; exit 1; }
test -d "$MIRROR/Inbox/Specs" && { echo "FAIL: the stub folder outlived the share"; exit 1; }
echo "ok: revoking the share took the stubs away"
rm -rf "$MIRROR" "$CLI_HOME"
