#!/usr/bin/env bash
# End to end in a real browser (#1220): Ask questions on a card (two, one
# added with Add a question), answer one by typing and the other with the
# ✨ suggestion from a stand-in model (tools/e2e/fake-ai.mjs) — the typed
# one must survive the suggestion — send them, then ask again and Skip;
# both show under Questions asked before.
#
#   tools/e2e/wait-questions.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
AI_PORT="${AI_PORT:-4197}"
AI_LOG="$(mktemp)"
export SLIPDOCK_AI_BASE_URL="http://127.0.0.1:$AI_PORT/v1" SLIPDOCK_AI_MODEL="fake/model" FAKE_AI_LOG="$AI_LOG"
export FAKE_AI_REPLY='{"answer": "eu-west-1"}'
node "$(dirname "$0")/fake-ai.mjs" "$AI_PORT" &
FAKE_AI=$!
source "$(dirname "$0")/lib.sh"
e2e_start
trap 'kill $E2E_SERVER $FAKE_AI 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

CARD=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(first, %{"title" => "Deploy", "description" => "Data must stay in the EU."})
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)

node tools/e2e/wait-questions.mjs "$LINK" "$BASE" "$KB" "$CARD" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

grep -q "Data must stay in the EU." "$AI_LOG" || { echo "FAIL: the model was not told the card"; exit 1; }
grep -q "1. Which region? ← answer this one" "$AI_LOG" || { echo "FAIL: the model was not told which question"; exit 1; }
echo "ok: the model was told the card and which question to answer"

mix run -e '
  [skipped, answered] = Slipdock.Boards.list_waits(%Slipdock.Boards.Card{id: '"$CARD"'})
  unless answered.questions == ["Which region?", "How many seats?"], do: raise("questions #{inspect(answered.questions)}")
  unless answered.answers == ["eu-west-1", "12"], do: raise("answers #{inspect(answered.answers)}")
  unless skipped.close_reason == "skipped", do: raise("second #{inspect(skipped.close_reason)}")
  IO.puts("ok: the database has both waits: answered [eu-west-1, 12], then skipped")
'
