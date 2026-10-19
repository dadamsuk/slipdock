defmodule Slipdock.Runners.PauseTest do
  @moduledoc """
  The brake (#1116, KTD10): a pool or a whole board tree paused with a
  reason holds claims and list_top sends, lets running jobs finish, is kept
  on the root, and on resume lets go of exactly what it held — at once.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Repo, Runners}
  alias Slipdock.Boards.Activity
  alias Slipdock.Runners.{Job, Pause}

  setup do
    david =
      user_fixture()
      |> Ecto.Changeset.change(name: "David")
      |> Repo.update!()

    board = board_fixture(%{"name" => "Brakes"}, owner: david)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, dev, _} = Runners.create_runner(board, %{"name" => "laptop", "pool" => "dev"})
    {:ok, ops, _} = Runners.create_runner(board, %{"name" => "server", "pool" => "ops"})

    %{david: david, board: board, todo: todo, doing: doing, dev: dev, ops: ops}
  end

  defp human(user), do: Actor.web(user)

  defp queue(card, pool),
    do: Runners.queue(card, %{pool: pool, kind: "claude", prompt: "go"})

  defp pause!(ctx, pool, reason, board \\ nil) do
    {:ok, pause} =
      Runners.pause(board || ctx.board, %{"pool" => pool, "reason" => reason}, ctx.david)

    pause
  end

  defp list_top(board, column, pool) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "list_top", "column" => column},
      "actions" => [%{"type" => "runner", "pool" => pool}]
    })
  end

  defp jobs(rule), do: Repo.all(from(j in Job, where: j.rule_id == ^rule.id))

  describe "a paused pool (AE5)" do
    test "a claim gets no job, and the held line says who paused it and why", ctx do
      {:ok, job} = queue(card_fixture(ctx.todo), "dev")
      pause!(ctx, "dev", "bad deploy")

      assert Runners.claim(ctx.dev) == nil
      assert Repo.reload!(job).status == "queued"
      assert %{reason: "paused by David: bad deploy", job: nil} = Runners.held(ctx.board, "dev")
      assert Runners.held_reason(Repo.reload!(job)) == "paused by David: bad deploy"

      # Another pool on the tree goes on as before.
      {:ok, other} = queue(card_fixture(ctx.todo), "ops")
      assert %Job{id: id} = Runners.claim(ctx.ops)
      assert id == other.id
    end

    test "a job already running finishes: its heartbeat still answers ok", ctx do
      {:ok, _} = queue(card_fixture(ctx.todo), "dev")
      job = Runners.claim(ctx.dev)
      pause!(ctx, "dev", "bad deploy")

      assert Runners.heartbeat(ctx.dev, job.id, "still going") == {:ok, :ok}
      assert {:ok, %Job{status: "done"}} = Runners.finish(ctx.dev, job.id, %{exit: "0"})
    end

    test "a list_top rule sends nothing while paused", ctx do
      card_fixture(ctx.todo, %{"title" => "Top"})
      pause!(ctx, "dev", "bad deploy")
      rule = list_top(ctx.board, "To Do", "dev")

      assert Automations.feed(rule) == {:idle, :paused}
      assert jobs(rule) == []
    end
  end

  describe "the whole tree" do
    test "holds every pool; resuming it leaves a pool's own pause in place", ctx do
      {:ok, _} = queue(card_fixture(ctx.todo), "dev")
      {:ok, _} = queue(card_fixture(ctx.todo), "ops")
      pause!(ctx, nil, "freeze for the release")
      pause!(ctx, "dev", "bad deploy")

      assert Runners.claim(ctx.dev) == nil
      assert Runners.claim(ctx.ops) == nil
      assert Runners.held(ctx.board, "ops").reason == "paused by David: freeze for the release"

      assert {:ok, %Pause{pool: nil}} =
               Runners.resume(ctx.board, nil, ctx.david, human(ctx.david))

      assert %Job{pool: "ops"} = Runners.claim(ctx.ops)
      assert Runners.claim(ctx.dev) == nil
      assert Runners.held(ctx.board, "dev").reason == "paused by David: bad deploy"
    end

    test "pausing from a sub-board keeps it on the root, and holds the sub-board's rules", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      epic = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, sub} = Boards.create_sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      ready = hd(sub.columns)
      card_fixture(ready, %{"title" => "Sub task"})

      pause = pause!(ctx, nil, "hold everything", sub)
      assert pause.root_board_id == ctx.board.id
      assert [%Pause{id: id}] = Runners.pauses(sub)
      assert id == pause.id

      rule = list_top(sub, ready.name, "dev")
      assert Automations.feed(rule) == {:idle, :paused}
      assert jobs(rule) == []

      # Resuming feeds every board in the tree: the sub-board's rule sends at once.
      {:ok, _} = Runners.resume(sub, nil, ctx.david, human(ctx.david))
      assert [%Job{status: "queued"}] = jobs(rule)
    end
  end

  describe "resuming" do
    test "wakes a runner waiting on a long poll, without waiting for the clock", ctx do
      {:ok, _} = queue(card_fixture(ctx.todo), "dev")
      pause!(ctx, "dev", "bad deploy")

      parent = self()

      task =
        Task.async(fn ->
          send(parent, :polling)
          Runners.claim(ctx.dev, 10_000)
        end)

      assert_receive :polling
      # Long enough for the claim to have looked once and subscribed.
      Process.sleep(150)
      started = System.monotonic_time(:millisecond)
      {:ok, _} = Runners.resume(ctx.board, "dev", ctx.david, human(ctx.david))

      assert %Job{status: "claimed"} = Task.await(task, 5_000)
      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "a list_top rule held by the pause sends as soon as it is resumed", ctx do
      card_fixture(ctx.todo, %{"title" => "Top"})
      pause!(ctx, "dev", "bad deploy")
      rule = list_top(ctx.board, "To Do", "dev")
      assert Automations.feed(rule) == {:idle, :paused}

      {:ok, _} = Runners.resume(ctx.board, "dev", ctx.david, human(ctx.david))
      assert [%Job{status: "queued"}] = jobs(rule)
    end

    test "is a person's: an agent's resume is refused and the pause stays", ctx do
      pause!(ctx, "dev", "bad deploy")

      for actor <- [Actor.mcp(%{user: ctx.david, token: %{label: "bot"}}), Actor.unknown()] do
        assert {:error, "only a person can resume" <> _} =
                 Runners.resume(ctx.board, "dev", ctx.david, actor)
      end

      assert [%Pause{pool: "dev"}] = Runners.pauses(ctx.board)
    end

    test "names exactly one scope: the tree's resume isn't a pool's", ctx do
      pause!(ctx, "dev", "bad deploy")

      assert {:error, "the whole tree is not paused"} =
               Runners.resume(ctx.board, nil, ctx.david, human(ctx.david))

      assert {:error, "pool ops is not paused"} =
               Runners.resume(ctx.board, "ops", ctx.david, human(ctx.david))

      assert [_] = Runners.pauses(ctx.board)
    end
  end

  describe "pausing" do
    test "needs a reason", ctx do
      for reason <- [nil, "", "   "] do
        assert {:error, %Ecto.Changeset{} = cs} =
                 Runners.pause(ctx.board, %{"pool" => "dev", "reason" => reason}, ctx.david)

        assert %{reason: [_]} = errors_on(cs)
      end

      assert Runners.pauses(ctx.board) == []
    end

    test "a pool name is checked, and the same scope can't be paused twice", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Runners.pause(ctx.board, %{"pool" => "Not a pool!", "reason" => "x"}, ctx.david)

      pause!(ctx, "dev", "bad deploy")

      assert {:error, "pool dev is already paused by David: bad deploy"} =
               Runners.pause(ctx.board, %{"pool" => "DEV", "reason" => "again"}, ctx.david)
    end

    test "logs who paused and resumed, with an agent's token label", ctx do
      agent = Actor.mcp(%{user: ctx.david, token: %{label: "laptop claude"}})

      {:ok, pause} =
        Runners.pause(ctx.board, %{"pool" => "dev", "reason" => "tests red"}, ctx.david, agent)

      assert Pause.line(Repo.preload(pause, :paused_by)) ==
               "paused by David (laptop claude): tests red"

      {:ok, _} = Runners.resume(ctx.board, "dev", ctx.david, human(ctx.david))

      lines =
        Repo.all(
          from(a in Activity,
            where: a.board_id == ^ctx.board.id and a.kind == "runner",
            select: a.message
          )
        )

      assert "David (laptop claude) paused pool dev: tests red" in lines
      assert "David resumed pool dev" in lines
    end
  end
end
