defmodule Slipdock.PendingReleaseTest do
  @moduledoc """
  Ship by PR 6 (#1661): on a board that ships by push, a card awaiting
  verification has its work on the default branch already, so it releases
  its lane and counts as finished for its dependents. A rejection brings
  both back. On a board that ships by pull request it keeps both until the
  merge.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Lanes, Rollup, Runners, Verified}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Release", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      builder: agent.("builder"),
      checker: agent.("checker")
    }
  end

  defp ship(ctx, via) do
    {:ok, board} =
      Boards.update_board(ctx.board, %{"verify_work" => true, "lanes" => true, "ship_via" => via})

    assert board.ship_via == via
    Map.put(ctx, :board, board)
  end

  defp card(column, title, paths) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.update_card(card, %{"paths" => paths})
    card
  end

  defp submit(card, ctx) do
    {:ok, card} =
      Boards.update_card(Repo.get!(Card, card.id), %{"completed" => true}, actor: ctx.builder)

    assert card.verify_state == "pending"
    refute card.completed
    card
  end

  defp reject(card, ctx) do
    {:ok, card} =
      Verified.decide(
        Repo.get!(Card, card.id),
        "reject",
        %{"reason" => "The empty case fails"},
        ctx.checker,
        ctx.owner
      )

    assert card.verify_state == "rejected"
    card
  end

  defp depend(blocked, blocker) do
    {:ok, _} = Boards.add_dependency(blocked, blocker)
    {:ok, _} = Boards.update_card(Repo.get!(Card, blocked.id), %{"flags" => ["blocked"]})
    :ok
  end

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  defp move(card, column, ctx), do: Boards.move_card(card.id, column.id, nil, actor: ctx.builder)

  describe "released?/2" do
    test "pending on a push board only", ctx do
      push = ship(ctx, "push")
      a = card(push.doing, "A", "lib/**") |> submit(push)
      assert Verified.released?(a)
      refute Verified.released?(%{a | verify_state: "rejected"})
      refute Verified.released?(%{a | verify_state: nil})

      {:ok, pr} = Boards.update_board(push.board, %{"ship_via" => "pull_request"})
      refute Verified.released?(Repo.get!(Card, a.id))
      refute Verified.released?(a, pr)
    end
  end

  describe "lanes" do
    test "on a push board a pending card's paths stop counting", ctx do
      ctx = ship(ctx, "push")
      a = card(ctx.doing, "A", "lib/**")
      b = card(ctx.todo, "B", "lib/a.ex")
      assert %Card{id: id} = Lanes.conflict(b)
      assert id == a.id

      submit(a, ctx)

      assert Lanes.conflict(b) == nil
      assert :ok = move(b, ctx.doing, ctx)
    end

    test "on a pull_request board a pending card keeps its lane", ctx do
      ctx = ship(ctx, "pull_request")
      a = card(ctx.doing, "A", "lib/**")
      b = card(ctx.todo, "B", "lib/a.ex")

      submit(a, ctx)

      assert %Card{id: id} = Lanes.conflict(b)
      assert id == a.id
      assert {:error, :unprocessable_entity, message} = move(b, ctx.doing, ctx)
      assert message =~ "##{a.id}"
    end

    test "a rejection takes the lane back, waiting for an overlapping card in progress", ctx do
      ctx = ship(ctx, "push")
      a = card(ctx.doing, "A", "lib/**")
      b = card(ctx.todo, "B", "lib/a.ex")
      submit(a, ctx)
      :ok = move(b, ctx.doing, ctx)

      a = reject(a, ctx)
      # Back on the ready list, out of the doing list.
      assert Repo.get!(Card, a.id).column_id == ctx.todo.id

      # The rework waits for B, as lanes normally do...
      assert {:error, :unprocessable_entity, message} = move(a, ctx.doing, ctx)
      assert message =~ "##{b.id}"

      # ...and takes its lane once B is out of the way, holding off others.
      {:ok, _} = Boards.update_card(Repo.get!(Card, b.id), %{"completed" => true})
      assert :ok = move(a, ctx.doing, ctx)
      c = card(ctx.todo, "C", "lib/b.ex")
      assert %Card{id: id} = Lanes.conflict(c)
      assert id == a.id
    end

    test "a queued job held by a pending card's lane goes on a push board only", ctx do
      ctx = ship(ctx, "push")
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})
      a = card(ctx.doing, "A", "lib/**")
      b = card(ctx.todo, "B", "lib/a.ex")
      {:ok, job} = Runners.queue(b, %{pool: "dev", kind: "claude", prompt: "go"})
      assert Runners.claim(runner) == nil

      submit(a, ctx)

      assert Runners.held_reason(Repo.reload!(job), claimant: true) == nil
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id
    end
  end

  describe "dependencies" do
    test "on a push board a pending blocker counts as finished and unblocks", ctx do
      ctx = ship(ctx, "push")
      a = card(ctx.doing, "A", "lib/**")
      d = card(ctx.todo, "D", "docs/**")
      :ok = depend(d, a)
      assert Card.blocked?(Boards.get_card!(d.id))

      submit(a, ctx)

      d = Boards.get_card!(d.id)
      refute Card.blocked?(d)
      assert Card.open_blockers(d) == []
      assert [%{verify_released: true}] = d.blocked_by
      refute "blocked" in d.flags
      assert Enum.any?(comments(d), &(&1 =~ "awaiting verification"))

      refute Rollup.build(ctx.board).stats[d.id].blocked
      assert d.id in Enum.map(Boards.list_cards(ctx.board, %{"deps" => "ready"}), & &1.id)

      # The API says so, for the CLI's blocked-by list.
      json = SlipdockWeb.API.JSON.card(d)
      refute json.blocked
      assert [%{id: id, released: true, completed: false}] = json.blocked_by
      assert id == a.id
    end

    test "a rejection makes the blocker count again", ctx do
      ctx = ship(ctx, "push")
      a = card(ctx.doing, "A", "lib/**")
      d = card(ctx.todo, "D", "docs/**")
      :ok = depend(d, a)
      submit(a, ctx)
      refute Card.blocked?(Boards.get_card!(d.id))

      reject(a, ctx)

      d = Boards.get_card!(d.id)
      assert Card.blocked?(d)
      assert [%{id: id}] = Card.open_blockers(d)
      assert id == a.id
      assert Rollup.build(ctx.board).stats[d.id].blocked
      refute d.id in Enum.map(Boards.list_cards(ctx.board, %{"deps" => "ready"}), & &1.id)
    end

    test "on a pull_request board dependents stay blocked until the card is done", ctx do
      ctx = ship(ctx, "pull_request")
      a = card(ctx.doing, "A", "lib/**")
      d = card(ctx.todo, "D", "docs/**")
      :ok = depend(d, a)

      submit(a, ctx)

      d = Boards.get_card!(d.id)
      assert Card.blocked?(d)
      assert [%{verify_released: false}] = d.blocked_by
      assert [%{released: false}] = SlipdockWeb.API.JSON.card(d).blocked_by
      assert "blocked" in d.flags
      assert Rollup.build(ctx.board).stats[d.id].blocked
      refute d.id in Enum.map(Boards.list_cards(ctx.board, %{"deps" => "ready"}), & &1.id)

      # Accepted (here by a person): done, and the dependent goes.
      {:ok, _} =
        Verified.decide(Repo.get!(Card, a.id), "accept", %{}, Actor.web(ctx.owner), ctx.owner)

      d = Boards.get_card!(d.id)
      refute Card.blocked?(d)
      refute "blocked" in d.flags
    end

    test "blocked_by preloaded through dependency_query sees the release", ctx do
      ctx = ship(ctx, "push")
      a = card(ctx.doing, "A", "lib/**")
      d = card(ctx.todo, "D", "docs/**")
      {:ok, _} = Boards.add_dependency(d, a)
      submit(a, ctx)

      # The automation's preload sees the release too (blocked_by stubs).
      card =
        Repo.get!(Card, d.id)
        |> Repo.preload(blocked_by: Boards.dependency_query())

      refute Card.blocked?(card)
    end
  end
end
