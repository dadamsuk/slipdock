#!/usr/bin/env bash
# End to end in a real browser (#1185): the Visualise page on a board with a
# month of history, a runner and deploys. Reached from the view menu; every
# section draws; the window switch changes the URL; on a desktop and a phone
# width, in light and dark, without the page scrolling sideways. Screenshots
# go to $SHOTS (/tmp unless set).
#
#   tools/e2e/visualise.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  import Ecto.Query
  alias Slipdock.{Boards, Deployments, Repo, Runners}
  alias Slipdock.Boards.{Card, CardMove}
  board = Boards.get_board!('"$KB"')
  {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
  [backlog, todo, doing, done] = board.columns
  {:ok, _} = Boards.update_column(doing, %{"wip_limit" => 3})
  {:ok, later} = Boards.create_column(board, %{"name" => "Maybe Later"})
  {:ok, bug} = Boards.create_tag(board, %{"name" => "bug", "color" => "rose"})
  {:ok, feat} = Boards.create_tag(board, %{"name" => "feature", "color" => "sky"})
  now = DateTime.utc_now()
  at = fn h -> DateTime.add(now, -round(h * 3600), :second) end
  row = fn card, kind, from, to, h ->
    Repo.insert!(%CardMove{card_id: card.id, kind: kind, board_id: board.id,
      from_board_id: from && board.id, from_column_id: from && from.id, from_category: from && from.category,
      from_column_name: from && from.name, to_column_id: to && to.id, to_category: to && to.category,
      to_column_name: to && to.name, inserted_at: at.(h), actor_kind: "human"})
  end
  :rand.seed(:exsss, {1, 2, 3})
  for n <- 1..60 do
    start = 30 * 24 * :rand.uniform()
    {:ok, c} = Boards.create_card(backlog, %{"title" => "Card #{n}: something to do"})
    Repo.delete_all(from m in CardMove, where: m.card_id == ^c.id)
    if rem(n, 3) == 0, do: Boards.set_card_tags(c, [bug]), else: if(rem(n, 4) == 0, do: Boards.set_card_tags(c, [feat]))
    row.(c, "created", nil, backlog, start)
    stage = rem(n, 6)
    {col, last} =
      cond do
        stage == 0 -> {backlog, start}
        true ->
          r = start * (0.6 + 0.3 * :rand.uniform())
          row.(c, "moved", backlog, todo, r)
          if stage == 1 do
            {todo, r}
          else
            d = r * (0.5 + 0.4 * :rand.uniform())
            row.(c, "moved", todo, doing, d)
            if stage == 2 do
              {doing, d}
            else
              f = d * :rand.uniform()
              row.(c, "moved", doing, done, f)
              {done, f}
            end
          end
      end
    set = [column_id: col.id, inserted_at: DateTime.truncate(at.(start), :second)]
    set = if col.id == done.id, do: set ++ [completed: true, completed_at: DateTime.truncate(at.(last), :second)], else: set
    Repo.update_all(from(x in Card, where: x.id == ^c.id), set: set)
  end
  {:ok, _} = Boards.create_card(later, %{"title" => "One day, perhaps"})

  {:ok, runner, _} = Runners.create_runner(board, %{"name" => "dev-box", "pool" => "dev"})
  cards = Repo.all(from c in Card, where: c.board_id == ^board.id, order_by: c.id, limit: 14)
  for {c, i} <- Enum.with_index(cards) do
    status = Enum.at(~w(done done done parked done failed done done done timeout done done done running), i)
    claimed = at.(14 * 24 - i * 24)
    Repo.insert!(%Slipdock.Runners.Job{pool: "dev", kind: "claude", prompt: "go", status: status,
      board_id: board.id, root_board_id: board.id, card_id: c.id, runner_id: runner.id,
      inserted_at: DateTime.add(claimed, -300, :second) |> DateTime.truncate(:second),
      claimed_at: DateTime.truncate(claimed, :second),
      finished_at: if(status != "running", do: DateTime.add(claimed, 600 + i * 120, :second) |> DateTime.truncate(:second)),
      error: if(status == "failed", do: "exit 1: tests failed")})
  end
  running = Repo.one(from j in Slipdock.Runners.Job, where: j.status == "running", limit: 1)
  Repo.update_all(from(r in Slipdock.Runners.Runner, where: r.id == ^runner.id),
    set: [current_job_id: running.id, last_seen_at: DateTime.truncate(now, :second)])
  Repo.update_all(from(j in Slipdock.Runners.Job, where: j.id == ^running.id), set: [claimed_at: at.(0.3) |> DateTime.truncate(:second)])

  commit = fn h -> %{"sha" => Base.encode16(:crypto.strong_rand_bytes(5), case: :lower),
    "committed_at" => DateTime.to_iso8601(at.(h)), "subject" => "work"} end
  for h <- [600, 500, 410, 400, 300, 220, 200, 150, 100, 60, 30, 10] do
    status = if h in [410, 150], do: "failed", else: "succeeded"
    {:ok, _} = Deployments.start(board, %{environment: "production",
      sha: Base.encode16(:crypto.strong_rand_bytes(10), case: :lower), status: status, tag: "v#{h}",
      started_at: at.(h), finished_at: at.(h - 0.2), commits: [commit.(h + 3), commit.(h + 9)]})
  end
' > /dev/null

node tools/e2e/visualise.mjs "$LINK" "$BASE" "$KB" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }
