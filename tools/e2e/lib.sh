# Shared by the tools/e2e scripts: a throwaway database with two boards in
# one vault (KnowledgeBase at /, Job Hunt at /Hunt), a folder Specs with a
# note "Acme call" in it, a server of its own, and a sign-in link. Source it,
# then call e2e_start; it sets KB HUNT SPECS PAGE LINK BASE, and the server
# and database go when the script exits.
set -euo pipefail

PORT="${PORT:-4112}"
DB="slipdock_e2e_$$"
LOG="$(mktemp -d)/server.log"
BASE="http://127.0.0.1:$PORT"

export DATABASE_URL="${E2E_DATABASE_URL:-postgres://postgres:postgres@localhost:5434/$DB}"
export SLIPDOCK_BIND_IP=127.0.0.1
export PORT
export SLIPDOCK_AGENTIC_LOGIN=true
export MIX_ENV=dev

e2e_start() {
  mix ecto.create --quiet
  mix ecto.migrate --quiet
  mix slipdock.setup --admin e2e@example.com > /dev/null

  local ids
  ids=$(mix run -e '
    alias Slipdock.{Accounts, Boards, Vaults, Wiki}
    {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
    {:ok, kb} = Boards.create_board(%{"name" => "KnowledgeBase", "code" => "kbe2e"}, owner_id: user.id)
    {:ok, hunt} = Boards.create_board(%{"name" => "Job Hunt", "code" => "hunte2e"}, owner_id: user.id)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: Boards.get_board!(kb.id)})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Hunt", board: Boards.get_board!(hunt.id)})
    {:ok, specs} = Wiki.create_folder(kb, %{"name" => "Specs"})
    {:ok, page} = Wiki.create_page(kb, %{"title" => "Acme call", "body" => "Went well.", "folder_id" => specs.id}, user: user)
    IO.puts("IDS #{kb.id} #{hunt.id} #{specs.id} #{page.id}")
  ' | grep '^IDS' | cut -d' ' -f2-)
  read -r KB HUNT SPECS PAGE <<<"$ids"

  mix phx.server > "$LOG" 2>&1 &
  E2E_SERVER=$!
  trap 'kill $E2E_SERVER 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

  for _ in $(seq 1 60); do
    curl -sf -o /dev/null "$BASE/login" && break
    sleep 2
  done

  LINK=$(mix run --no-start -e '
    {:ok, _} = Application.ensure_all_started(:slipdock)
    {:ok, path} = Slipdock.Accounts.write_agentic_login("e2e@example.com", &"'"$BASE"'/login/#{&1}")
    IO.write(File.read!(path))
    File.rm(path)
  ' | tail -1)
}
