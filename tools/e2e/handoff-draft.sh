#!/usr/bin/env bash
# End to end in a real browser (#1099): Leave a handoff → Auto generate asks
# a stand-in model (tools/e2e/fake-ai.mjs), shows Generating… meanwhile, and
# puts its draft in the form's fields for the person to change and save;
# nothing is written until they do.
#
#   tools/e2e/handoff-draft.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
AI_PORT="${AI_PORT:-4198}"
AI_LOG="$(mktemp)"
export SLIPDOCK_AI_BASE_URL="http://127.0.0.1:$AI_PORT/v1" SLIPDOCK_AI_MODEL="fake/model" FAKE_AI_LOG="$AI_LOG"
node "$(dirname "$0")/fake-ai.mjs" "$AI_PORT" &
FAKE_AI=$!
source "$(dirname "$0")/lib.sh"
e2e_start
trap 'kill $E2E_SERVER $FAKE_AI 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

CARD=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(first, %{"title" => "Wire up billing"})
  {:ok, _} = Boards.add_comment(card, "Webhook signature check fails on staging")
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)

node tools/e2e/handoff-draft.mjs "$LINK" "$BASE" "$KB" "$CARD" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

grep -q "Webhook signature check fails on staging" "$AI_LOG" || { echo "FAIL: the model was not told the card's comment"; exit 1; }
echo "ok: the model was told the card's recent comment"

mix run -e '
  h = Slipdock.Boards.current_handoff('"$CARD"')
  unless h && h.next_step == "Fix the webhook signature check today", do: raise("saved #{inspect(h && h.next_step)}")
  unless h.body =~ "Gotchas: staging secret differs", do: raise("body #{inspect(h.body)}")
  IO.puts("ok: the database has the edited draft, as saved")
'
