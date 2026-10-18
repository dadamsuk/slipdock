#!/usr/bin/env bash
# End to end in a real browser: a tab still running the assets from before a
# deploy sees the "Slipdock has been updated" bar (SlipdockWeb.StaleAssetsHook),
# and its Reload link brings it up to date.
#
#   tools/e2e/stale-assets.sh
#
# A dev server has no static manifest, so nothing is ever stale there. This
# one runs as a named node and is given a manifest over RPC, as if a newer
# build were deployed; the browser's HTML is rewritten to name the old
# digests. Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"

mix ecto.create --quiet
mix ecto.migrate --quiet
mix slipdock.setup --admin e2e@example.com > /dev/null

NODE="e2estale$$"
elixir --sname "$NODE" -S mix phx.server > "$LOG" 2>&1 &
E2E_SERVER=$!
trap 'kill $E2E_SERVER 2>/dev/null || true; fuser -k '"$PORT"'/tcp 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -sf -o /dev/null "$BASE/login" && break
  sleep 2
done

elixir --sname "ctl$$" -e '
  manifest = %{
    "assets/js/app.js" => "assets/js/app-new.js",
    "assets/css/app.css" => "assets/css/app-new.css",
    "assets/js/theme.js" => "assets/js/theme-new.js"
  }
  true = :rpc.call(:"'"$NODE@$(hostname -s)"'", Phoenix.Config, :put,
    [SlipdockWeb.Endpoint, :cache_static_manifest_latest, manifest])
'

LINK=$(mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:slipdock)
  {:ok, path} = Slipdock.Accounts.write_agentic_login("e2e@example.com", &"'"$BASE"'/login/#{&1}")
  IO.write(File.read!(path))
  File.rm(path)
' | tail -1)

node tools/e2e/stale-assets.mjs "$LINK" "$BASE"
