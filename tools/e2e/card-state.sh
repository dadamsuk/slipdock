#!/usr/bin/env bash
# End to end in a real browser (#1117): a tile with a running job shows its
# state line and an agent mark; a card past its list's usual stay has an
# amber age chip; the Filter menu's Stuck shows it alone, and Agent / Human
# on a tree with a runner rule picks out the agent's card.
#
#   tools/e2e/card-state.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

IDS=$(mix run -e '
  import Ecto.Query
  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Boards.CardMove
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [_, _, doing, done | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, runner, _} = Runners.create_runner(board, %{"name" => "runner-2", "pool" => "dev"})

  {:ok, _} =
    Slipdock.Automations.create_rule(%{
      "name" => "Send", "board_id" => board.id,
      "spec" => %{"trigger" => %{"type" => "flag_added", "flag" => "blocked"},
                  "actions" => [%{"type" => "runner", "pool" => "dev"}]}
    })

  start = DateTime.add(DateTime.utc_now(), -3 * 86_400)
  for _ <- 1..8 do
    {:ok, c} = Boards.create_card(done, %{"title" => "Old"})
    Repo.delete_all(from m in CardMove, where: m.card_id == ^c.id)
    Repo.insert!(%CardMove{card_id: c.id, kind: "created", board_id: board.id, to_column_id: doing.id, inserted_at: start})
    Repo.insert!(%CardMove{card_id: c.id, kind: "moved", board_id: board.id, from_column_id: doing.id, to_column_id: done.id, inserted_at: DateTime.add(start, 7200)})
  end

  {:ok, slow} = Boards.create_card(doing, %{"title" => "Slow"})
  Repo.update_all(from(m in CardMove, where: m.card_id == ^slow.id), set: [inserted_at: DateTime.add(DateTime.utc_now(), -(3 * 3600 + 30))])

  {:ok, build} = Boards.create_card(doing, %{"title" => "Build"})
  {:ok, _} = Runners.queue(build, %{pool: "dev", kind: "claude", prompt: "go"})
  job = Runners.claim(runner)
  {:ok, :ok} = Runners.heartbeat(runner, job.id)
  IO.puts("IDS #{slow.id} #{build.id}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r SLOW BUILD <<< "$IDS"

node tools/e2e/card-state.mjs "$LINK" "$BASE" "$KB" "$SLOW" "$BUILD" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
