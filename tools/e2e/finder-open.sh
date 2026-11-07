#!/usr/bin/env bash
# End to end in a real browser: a card opened from the Ctrl-O finder stays
# open (#2019). The finder's row is a `navigate`, a fresh mount, and a fresh
# mount restores the board's remembered Display options; that restore used to
# patch to the board's bare address, closing the card and taking the
# "Slipdock has been updated" bar with it.
#
#   tools/e2e/finder-open.sh            # SHOTS=<dir> keeps screenshots
#
# Checks a completed card far down a long Done list, and a card being written
# to over the API while it is open, in a tab from before a deploy (the bar
# shows and stays) and in an up-to-date one (no bar). Runs as a named node and
# is given a manifest over RPC, as stale-assets.sh does. Needs playwright-core
# on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"

mix ecto.create --quiet
mix ecto.migrate --quiet
mix slipdock.setup --admin e2e@example.com > /dev/null

seed=$(mix run -e '
  alias Slipdock.{Accounts, Boards}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, board} = Boards.create_board(%{"name" => "Finder", "code" => "finde2e"}, owner_id: user.id)
  [_backlog, _todo, doing, done] = Boards.get_board!(board.id).columns
  for n <- 1..60, do: {:ok, _} = Boards.create_card(done, %{"title" => "Shipped #{n}"})
  {:ok, deep} = Boards.create_card(done, %{"title" => "Deep in Done"})
  {:ok, _} = Boards.update_card(deep, %{"completed" => true})
  {:ok, busy} = Boards.create_card(doing, %{"title" => "Being written to"})
  {token, _} = Accounts.create_api_token(user, "e2e")
  IO.puts("SEED #{board.id} #{deep.id} #{busy.id} #{token}")
' | grep '^SEED' | cut -d' ' -f2-)
read -r BOARD DEEP BUSY TOKEN <<<"$seed"

NODE="e2efinder$$"
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

node tools/e2e/finder-open.mjs "$LINK" "$BASE" "$BOARD" "$DEEP" "$BUSY" "$TOKEN"
