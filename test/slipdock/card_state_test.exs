defmodule Slipdock.CardStateTest do
  @moduledoc """
  A card's derived state (#1117, `Slipdock.CardState`): the one line saying
  what is happening to it, who is driving it, and how long it has sat in its
  list against the list's usual stay — worked out for a whole board in a
  fixed number of queries.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, CardState, Repo, Runners}
  alias Slipdock.Boards.{Card, CardMove, Wait}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture() |> Ecto.Changeset.change(name: "David") |> Repo.update!()
    board = board_fixture(%{"name" => "State"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "runner-2", "pool" => "dev"})

    %{
      owner: owner,
      board: board,
      backlog: backlog,
      todo: todo,
      doing: doing,
      done: done,
      runner: runner
    }
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)

  defp queue(card), do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

  defp set_job(job, set), do: Repo.update_all(from(j in Job, where: j.id == ^job.id), set: set)

  defp runner_rule(board) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "card_created"},
      "actions" => [%{"type" => "runner", "pool" => "dev"}]
    })
  end

  # The card as listed: its state worked out the way the API's are.
  defp state_of(ctx, card, filters \\ %{}) do
    ctx.board
    |> Boards.list_cards(filters)
    |> Enum.find(&(&1.id == card.id))
    |> case do
      nil -> nil
      card -> card.state
    end
  end

  defp entered(card, seconds_ago) do
    at = DateTime.utc_now() |> DateTime.add(-seconds_ago)
    Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [inserted_at: at])
  end

  defp mcp, do: %{Actor.unknown() | kind: "agent", via: "mcp", agent: "claude"}

  describe "the state line" do
    test "a running job: Running, the runner, and how long; an agent drives it", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Build"})
      {:ok, _} = queue(card)
      job = Runners.claim(ctx.runner)
      {:ok, :ok} = Runners.heartbeat(ctx.runner, job.id)
      set_job(job, started_at: ago(7 * 60 + 5))

      state = state_of(ctx, card)
      assert state.line == "Running · runner-2 · 7m"
      assert state.driver == "agent"
    end

    test "a claimed job not yet started says Claimed", ctx do
      card = card_fixture(ctx.doing)
      {:ok, _} = queue(card)
      job = Runners.claim(ctx.runner)
      set_job(job, claimed_at: ago(90))

      assert state_of(ctx, card).line == "Claimed · runner-2 · 1m"
    end

    test "a queued job held by a pause shows the held line", ctx do
      card = card_fixture(ctx.todo)
      {:ok, _} = queue(card)
      {:ok, _} = Runners.pause(ctx.board, %{"pool" => "dev", "reason" => "bad deploy"}, ctx.owner)

      state = state_of(ctx, card)
      assert state.line == "Held · paused by David: bad deploy"
      assert state.held == "paused by David: bad deploy"
      # Nobody holds a queued card yet.
      assert state.driver == nil
    end

    test "a queued job nothing holds says Queued, with its pool", ctx do
      Repo.update_all(
        from(r in Runners.Runner, where: r.id == ^ctx.runner.id),
        set: [last_seen_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )

      card = card_fixture(ctx.todo)
      {:ok, _} = queue(card)

      assert state_of(ctx, card).line =~ ~r/^Queued · dev · /
    end

    test "an open wait: who it waits on and for how long, and never amber", ctx do
      dana =
        user_fixture("dana@example.com") |> Ecto.Changeset.change(name: "Dana") |> Repo.update!()

      card = card_fixture(ctx.doing)
      entered(card, 10 * 86_400)

      {:ok, wait} =
        Boards.open_wait(card, Actor.web(ctx.owner), %{
          "needs" => "Region?",
          "on_user_id" => dana.id
        })

      Repo.update_all(from(w in Wait, where: w.id == ^wait.id), set: [inserted_at: ago(41 * 60)])
      # A usual stay the card is far past: the wait, not the card, is the hold-up.
      usual = %{ctx.doing.id => 3600}
      [card] = CardState.put([Boards.get_card!(card.id)], ctx.board, usual: usual)

      assert card.state.line == "Waiting on Dana · 41m"
      assert card.state.over_usual == nil
      refute card.state.stuck
    end

    test "a wait on nobody in particular waits on anyone", ctx do
      card = card_fixture(ctx.todo)
      {:ok, _} = Boards.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Anyone?"})

      assert state_of(ctx, card).line =~ ~r/^Waiting on anyone · /
    end

    test "a handoff or a review flag alone, with no job or wait, says nothing", ctx do
      handed = card_fixture(ctx.doing)
      {:ok, _} = Boards.leave_handoff(handed, ctx.owner, %{next_step: "Ship it", via: "ui"})
      flagged = card_fixture(ctx.doing, %{"flags" => ["review"]})

      for card <- [handed, flagged] do
        state = state_of(ctx, card)
        assert state.line == nil

        json =
          SlipdockWeb.API.JSON.card(Enum.find(Boards.list_cards(ctx.board), &(&1.id == card.id)))

        refute Map.has_key?(json, :state)
      end
    end

    test "a failed job, then the open handoff's next step", ctx do
      card = card_fixture(ctx.doing)
      {:ok, _} = queue(card)
      job = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "failed"})
      set_job(job, finished_at: ago(2 * 3600 + 60))
      {:ok, _} = Boards.leave_handoff(card, ctx.owner, %{next_step: "Fix the test", via: "ui"})

      assert state_of(ctx, card).line == "Failed · runner-2 · 2h ago · Next: Fix the test"
    end

    test "a failed job on a completed card says nothing", ctx do
      card = card_fixture(ctx.doing)
      {:ok, _} = queue(card)
      job = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "failed"})
      {:ok, _} = Boards.toggle_completed(Repo.get!(Card, card.id))

      assert state_of(ctx, card).line == nil
    end

    test "a finished job says nothing", ctx do
      card = card_fixture(ctx.doing)
      {:ok, _} = queue(card)
      job = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})

      assert state_of(ctx, card).line == nil
    end
  end

  describe "the driver" do
    test "a tree with no runner rule has none, even for a card an agent moved", ctx do
      card = card_fixture(ctx.todo)
      Boards.move_card(card.id, ctx.doing.id, nil, actor: mcp())

      assert state_of(ctx, card).driver == nil
      json = SlipdockWeb.API.JSON.card(hd(Boards.list_cards(ctx.board)))
      refute Map.has_key?(json, :driver)
    end

    test "on a runner tree: agent when an agent moved it last, human for a person", ctx do
      runner_rule(ctx.board)
      by_agent = card_fixture(ctx.todo)
      Boards.move_card(by_agent.id, ctx.doing.id, nil, actor: mcp())
      by_person = card_fixture(ctx.todo)
      Boards.move_card(by_person.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))

      assert state_of(ctx, by_agent).driver == "agent"
      assert state_of(ctx, by_person).driver == "human"

      assert Enum.map(Boards.list_cards(ctx.board, %{"driver" => "agent"}), & &1.id) == [
               by_agent.id
             ]

      assert Enum.map(Boards.list_cards(ctx.board, %{"driver" => "human"}), & &1.id) == [
               by_person.id
             ]

      assert length(Boards.list_cards(ctx.board, %{"driver" => "all"})) == 2
    end

    test "a runner rule on a sub-board makes the root a runner tree", ctx do
      parent = card_fixture(ctx.todo)
      {:ok, template} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(parent, template)
      runner_rule(sub)

      assert CardState.runner_tree?(ctx.board.id)
    end

    test "an agent's job holding the card beats a person's last move", ctx do
      runner_rule(ctx.board)
      card = card_fixture(ctx.todo)
      Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      {:ok, _} = queue(card)
      # The rule queued one when the card was made: that one is taken, and
      # the second waits behind it. The one being worked is the card's job.
      %Job{status: "claimed"} = Runners.claim(ctx.runner)

      assert state_of(ctx, card).driver == "agent"
    end
  end

  describe "the age chip" do
    # Eight cards that each sat in Doing for `secs` and moved on: enough
    # closed stays for the list's own usual stay.
    defp history(ctx, secs) do
      for _ <- 1..8 do
        card = card_fixture(ctx.doing)
        Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id))
        start = DateTime.add(DateTime.utc_now(), -(secs + 86_400))
        row(card, "created", nil, ctx.doing, start)
        row(card, "moved", ctx.doing, ctx.done, DateTime.add(start, secs))
        Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [column_id: ctx.done.id])
      end
    end

    defp row(card, kind, from, to, at) do
      Repo.insert!(%CardMove{
        card_id: card.id,
        kind: kind,
        board_id: card.board_id,
        from_column_id: from && from.id,
        from_column_name: from && from.name,
        from_category: from && from.category,
        to_column_id: to && to.id,
        to_column_name: to && to.name,
        to_category: to && to.category,
        inserted_at: at
      })
    end

    test "AE7: 3h into a list that usually takes 2h is amber, 1h over, and stuck", ctx do
      history(ctx, 2 * 3600)
      card = card_fixture(ctx.doing, %{"title" => "Slow"})
      entered(card, 3 * 3600 + 30)
      fresh = card_fixture(ctx.doing, %{"title" => "Fresh"})

      state = state_of(ctx, card)
      assert state.usual == 7200
      assert state.stuck
      assert CardState.age_text(state) == "3h · 1h over usual"
      refute state_of(ctx, fresh).stuck

      assert Enum.map(Boards.list_cards(ctx.board, %{"stuck" => "true"}), & &1.id) == [card.id]

      json = SlipdockWeb.API.JSON.card(hd(Boards.list_cards(ctx.board, %{"stuck" => "true"})))
      assert json.stuck == true
      assert json.over_usual >= 3600
      assert json.usual_stay == 7200
    end

    test "a card in a done list shows no colour", ctx do
      history(ctx, 60)
      card = card_fixture(ctx.done)
      entered(card, 10 * 86_400)
      # Done's own stays: none closed, so lend it Doing's figure to be sure.
      [card] = CardState.put([Boards.get_card!(card.id)], ctx.board, usual: %{ctx.done.id => 60})

      assert card.state.age >= 10 * 86_400
      refute card.state.stuck
      assert CardState.age_text(card.state) == "10d"
    end

    test "with too little history the age is plain", ctx do
      card = card_fixture(ctx.doing)
      entered(card, 5 * 86_400)

      state = state_of(ctx, card)
      assert state.usual == nil
      refute state.stuck
      assert CardState.age_text(state) == "5d"
    end

    test "a backfill gap: plain age from the last row, no colour, not in the P85", ctx do
      history(ctx, 2 * 3600)
      card = card_fixture(ctx.todo)
      Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id))
      # Recorded as created in To Do, but it is in Doing: the move wasn't read.
      row(card, "created", nil, ctx.todo, DateTime.add(DateTime.utc_now(), -30 * 3600))
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [column_id: ctx.doing.id])

      state = state_of(ctx, card)
      refute state.known
      assert state.age >= 30 * 3600
      assert state.usual == nil
      refute state.stuck
      refute Map.has_key?(CardState.to_map(state), :in_list_since)
      assert Slipdock.Pulse.usual_stays(ctx.board)[ctx.doing.id] == 7200
    end
  end

  test "the board page works states out in the same number of queries, whatever its size",
       ctx do
    runner_rule(ctx.board)

    add = fn n ->
      for i <- 1..n do
        card = card_fixture(ctx.doing)

        case rem(i, 3) do
          0 -> Boards.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Q#{i}?"})
          1 -> Boards.leave_handoff(card, ctx.owner, %{next_step: "N#{i}", via: "ui"})
          _ -> :ok
        end
      end
    end

    add.(3)
    small = count_queries(fn -> Boards.get_board!(ctx.board.id) end)
    add.(9)
    {big, board} = count_queries(fn -> Boards.get_board!(ctx.board.id) end, true)

    assert big == small
    assert board.runner_tree

    assert board.columns
           |> Enum.flat_map(& &1.cards)
           |> Enum.all?(&match?(%CardState{}, &1.state))
  end

  defp count_queries(fun, keep \\ false) do
    me = self()
    id = "card-state-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:slipdock, :repo, :query],
      fn _, _, _, _ -> if self() == me, do: send(me, :query) end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    n = drain(0)
    if keep, do: {n, result}, else: n
  end

  defp drain(n) do
    receive do
      :query -> drain(n + 1)
    after
      0 -> n
    end
  end
end
