#!/usr/bin/env bash
# End to end in a real browser (#746): drag a folder onto another board in a
# vault's tree, see what goes with it, confirm, and check it moved. LiveView
# tests can't drag; this drives the tree's pointer handling itself.
#
#   tools/e2e/folder-move-drag.sh [port]
#
# A throwaway database and a server of its own, as tools/screenshots.sh has.
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
set -euo pipefail

PORT="${1:-4112}"
DB="slipdock_e2e_$$"
LOG="$(mktemp -d)/server.log"
BASE="http://127.0.0.1:$PORT"

export DATABASE_URL="${E2E_DATABASE_URL:-postgres://postgres:postgres@localhost:5434/$DB}"
export SLIPDOCK_BIND_IP=127.0.0.1
export PORT
export SLIPDOCK_AGENTIC_LOGIN=true
export MIX_ENV=dev

mix ecto.create --quiet
mix ecto.migrate --quiet
mix slipdock.setup --admin e2e@example.com

# Two boards in one vault, and a folder with a page in it to move.
ids=$(mix run -e '
  alias Slipdock.{Accounts, Boards, Vaults, Wiki}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, kb} = Boards.create_board(%{"name" => "KnowledgeBase", "code" => "kbe2e"}, owner_id: user.id)
  {:ok, hunt} = Boards.create_board(%{"name" => "Job Hunt", "code" => "hunte2e"}, owner_id: user.id)
  {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
  {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
  {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Hunt", board: hunt})
  {:ok, specs} = Wiki.create_folder(kb, %{"name" => "Specs"})
  {:ok, page} = Wiki.create_page(kb, %{"title" => "Acme call", "folder_id" => specs.id}, user: user)
  IO.puts("IDS #{kb.id} #{hunt.id} #{specs.id} #{page.id}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r KB HUNT SPECS PAGE <<<"$ids"

mix phx.server > "$LOG" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -sf -o /dev/null "$BASE/login" && break
  sleep 2
done

link=$(mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:slipdock)
  {:ok, path} = Slipdock.Accounts.write_agentic_login("e2e@example.com", &"'"$BASE"'/login/#{&1}")
  IO.write(File.read!(path))
  File.rm(path)
' | tail -1)

node tools/e2e/folder-move-drag.mjs "$link" "$BASE" "$KB" "$HUNT"

# The folder and its page are on Job Hunt now, in the database itself.
mix run -e '
  folder = Slipdock.Repo.get!(Slipdock.Wiki.Folder, '"$SPECS"')
  page = Slipdock.Repo.get!(Slipdock.Wiki.Page, '"$PAGE"')
  unless folder.board_id == '"$HUNT"' and page.board_id == '"$HUNT"' and page.folder_id == folder.id,
    do: raise("not moved: #{inspect({folder.board_id, page.board_id, page.folder_id})}")
  IO.puts("ok: the folder and its page are on Job Hunt")
'
