#!/usr/bin/env bash
# End to end in a real browser (#1131): a card that has been through To Do,
# In Progress, a wait and a runner job shows a Timeline near the bottom of
# its panel: a lane each for lists, waits and jobs, spans in time order and
# sized by how long they lasted, with the stays listed under them.
#
#   tools/e2e/card-timeline.sh       (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

ID=$(mix run -e '
  import Ecto.Query
  alias Slipdock.{Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.{CardMove, Wait}
  alias Slipdock.Runners.Job
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [_, todo, doing | _] = Enum.sort_by(board.columns, & &1.position)
  user = Repo.get!(Slipdock.Accounts.User, board.owner_id)
  {:ok, card} = Boards.create_card(todo, %{"title" => "Travelled"})
  :ok = Boards.move_card(card.id, doing.id, nil, actor: Actor.web(user))
  now = DateTime.utc_now()
  at = fn h -> DateTime.add(now, -round(h * 3600)) end
  Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id and m.kind == "created"), set: [inserted_at: at.(10)])
  Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id and m.kind == "moved"), set: [inserted_at: at.(4)])
  {:ok, w} = Boards.open_wait(card, Actor.web(user), %{"needs" => "Which colour?"})
  {:ok, _} = Boards.answer_wait(card, Actor.web(user), %{"answer" => "Blue"})
  Repo.update_all(from(x in Wait, where: x.id == ^w.id), set: [inserted_at: DateTime.truncate(at.(3), :second), closed_at: DateTime.truncate(at.(2), :second)])
  {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
  Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [inserted_at: DateTime.truncate(at.(1.5), :second)])
  IO.puts("ID #{card.id} #{job.id}")
' | grep '^ID' | cut -d' ' -f2-)
read -r CARD JOB <<< "$ID"

node tools/e2e/card-timeline.mjs "$LINK" "$BASE" "$KB" "$CARD" "$JOB" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
