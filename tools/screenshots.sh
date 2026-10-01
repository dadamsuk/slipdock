#!/usr/bin/env bash
# Rebuilds the README screenshots end to end: a throwaway database with the
# demo workspace in it, a server of its own on a spare port, a magic link, and
# then tools/screenshots.mjs to photograph it. Nothing touches your own data.
#
#   tools/screenshots.sh [port] [out-dir]
#
# Needs playwright-core on NODE_PATH and a Chrome/Chromium binary (CHROME_PATH).
set -euo pipefail

PORT="${1:-4111}"
OUT="${2:-docs/screenshots}"
DB="$(mktemp -d)/demo.db"
BASE="http://127.0.0.1:$PORT"

export DATABASE_PATH="$DB"
export KANBAN_BIND_IP=127.0.0.1
export PORT
export KANBAN_AGENTIC_LOGIN=true
export MIX_ENV=dev

mix ecto.create --quiet
mix ecto.migrate --quiet
mix slipdock.demo

mix phx.server > "$DB.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
  curl -sf -o /dev/null "$BASE/login" && break
  sleep 2
done

link=$(mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:slipdock)
  email = Slipdock.Demo.owner_email()
  {:ok, path} = Slipdock.Accounts.write_agentic_login(email, &"'"$BASE"'/login/#{&1}")
  IO.write(File.read!(path))
  File.rm(path)
')

node tools/screenshots.mjs "$link" "$BASE" "$OUT"
