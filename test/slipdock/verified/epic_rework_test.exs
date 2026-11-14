defmodule Slipdock.Verified.EpicReworkTest do
  @moduledoc """
  A rejected subcard's rework when its epic's job has ended (#3184): the
  epic goes back on its feed by itself, and an epic left in progress with a
  rework and no job shows in Right now and the health monitor, with why.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Now, Repo, Runners, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Health.{Context, Settings}
  alias Slipdock.Health.Detectors.StalledRework
  alias Slipdock.Runners.Job
  alias Slipdock.Verified.EpicRework

  setup do
    owner = user_fixture("epic-rework@example.com")
    board = board_fixture(%{"name" => "Epics", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    [backlog, todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})

    rule =
      rule_fixture(board, %{
        "trigger" => %{"type" => "list_top", "column" => "To Do", "unassigned" => true},
        "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 2}]
      })

    epic = card_fixture(todo, %{"title" => "Policies"})

    template = %Boards.Template{
      name: "Breakdown",
      columns: [
        %{"name" => "To Do", "category" => "todo"},
        %{"name" => "In Progress", "category" => "doing"},
        %{"name" => "Done", "category" => "done"}
      ]
    }

    {:ok, sub} = sub_board(epic, template)
    [sub_todo, sub_doing | _] = Boards.get_board!(sub.id).columns
    subcard = card_fixture(sub_todo, %{"title" => "Policy 1"})

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{
      owner: owner,
      board: board,
      backlog: backlog,
      template: template,
      todo: todo,
      doing: doing,
      sub_todo: sub_todo,
      sub_doing: sub_doing,
      runner: runner,
      rule: rule,
      epic: epic,
      subcard: subcard,
      builder: agent.("builder"),
      checker: agent.("checker")
    }
  end

  defp card!(card), do: Repo.get!(Card, card.id)

  defp open_jobs(rule),
    do:
      Repo.all(
        from(j in Job,
          where: j.rule_id == ^rule.id and j.status in ^Job.open_statuses(),
          select: j.card_id
        )
      )

  # The #3167 case up to the verdict: a runner takes the epic, builds its
  # first subcard, submits it and, with `finish`, ends its job, leaving the
  # epic in progress to wait for the verdict.
  defp build_first_subcard(ctx, finish \\ true) do
    job = Runners.claim(ctx.runner)
    assert job.card_id == ctx.epic.id
    builder = %{ctx.builder | via: "runner", job_id: job.id}
    :ok = Boards.Cards.move_card_to_index(card!(ctx.epic), ctx.doing, :top, actor: builder)
    :ok = Boards.Cards.move_card_to_index(card!(ctx.subcard), ctx.sub_doing, :top, actor: builder)

    {:ok, sub} =
      Boards.Cards.update_card(card!(ctx.subcard), %{"completed" => true}, actor: builder)

    assert sub.verify_state == "pending"
    if finish, do: {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})
    job
  end

  defp reject(ctx) do
    {:ok, _} =
      Verified.decide(
        card!(ctx.subcard),
        "reject",
        %{"reason" => "bar 1: the policy is missing"},
        ctx.checker,
        ctx.owner
      )
  end

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  describe "a rejection sends the epic again (#3167)" do
    test "with the epic's job ended, the epic goes back to the top of To Do and is fed", ctx do
      job = build_first_subcard(ctx)
      assert card!(ctx.epic).column_id == ctx.doing.id
      assert Repo.reload!(job).status == "done"

      reject(ctx)

      assert card!(ctx.subcard).column_id == ctx.sub_todo.id
      epic = card!(ctx.epic)
      assert epic.column_id == ctx.todo.id
      assert epic.position == 0
      # The feed sends it at once, cool-down or not: the rejection is new.
      assert open_jobs(ctx.rule) == [ctx.epic.id]

      assert Enum.any?(
               comments(epic),
               &(&1 =~ "**Sent again:** ##{ctx.subcard.id}" and &1 =~ "top of To Do")
             )

      assert Now.snapshot(ctx.board).in_progress |> Enum.find(&(&1.id == ctx.epic.id)) == nil
    end

    test "with the epic's job still open, the epic stays where it is", ctx do
      job = build_first_subcard(ctx, false)
      reject(ctx)

      assert card!(ctx.epic).column_id == ctx.doing.id
      assert open_jobs(ctx.rule) == [ctx.epic.id]
      assert Repo.reload!(job).status in ~w(claimed running)
      refute Enum.any?(comments(card!(ctx.epic)), &(&1 =~ "Sent again"))
    end

    test "a job open on the subcard holds it too, and a verify job doesn't", ctx do
      build_first_subcard(ctx)

      verify =
        Repo.insert!(%Job{
          board_id: ctx.subcard.board_id,
          root_board_id: ctx.board.id,
          card_id: ctx.subcard.id,
          pool: "loop",
          kind: "verify",
          prompt: "",
          status: "running"
        })

      build =
        Repo.insert!(%Job{
          board_id: ctx.subcard.board_id,
          root_board_id: ctx.board.id,
          card_id: ctx.subcard.id,
          pool: "loop",
          kind: "claude",
          prompt: "",
          status: "queued"
        })

      reject(ctx)
      assert card!(ctx.epic).column_id == ctx.doing.id

      Repo.delete!(build)
      assert {:sent, _, column} = EpicRework.send_again(card!(ctx.subcard))
      assert column.id == ctx.todo.id
      assert Repo.reload!(verify).status == "running"
    end

    test "a subcard waiting on a person isn't sent: the answer sends it", ctx do
      build_first_subcard(ctx)

      {:ok, _} =
        Boards.Waits.open_wait(card!(ctx.subcard), Actor.web(ctx.owner), %{"needs" => "Which?"})

      reject(ctx)

      assert card!(ctx.epic).column_id == ctx.doing.id
      assert EpicRework.send_again(card!(ctx.subcard)) == :held
      assert EpicRework.stalled([ctx.epic.id]) == %{}
    end

    test "an epic a person put in progress is never moved, nor named stalled", ctx do
      mine = card_fixture(ctx.backlog, %{"title" => "Mine"})
      :ok = Boards.Cards.move_card_to_index(mine, ctx.doing, :top, actor: Actor.web(ctx.owner))
      {:ok, sub} = sub_board(card!(mine), ctx.template)
      [sub_todo | _] = Boards.get_board!(sub.id).columns
      subcard = card_fixture(sub_todo, %{"title" => "Theirs"})

      Repo.update_all(from(c in Card, where: c.id == ^subcard.id),
        set: [verify_state: "rejected", verify_at: DateTime.utc_now(:second)]
      )

      assert EpicRework.send_again(card!(subcard)) == :in_place
      assert card!(mine).column_id == ctx.doing.id
      assert EpicRework.stalled([mine.id]) == %{}
    end

    test "a card under no epic, and an epic not in progress, are left alone", ctx do
      loose = card_fixture(ctx.todo, %{"title" => "Loose"})
      assert EpicRework.send_again(loose) == :none
      # The feed's job for the epic, still queued, holds it: none here.
      Repo.delete_all(from(j in Job, where: j.card_id == ^ctx.epic.id))

      Repo.update_all(from(c in Card, where: c.id == ^ctx.subcard.id),
        set: [verify_state: "rejected", verify_at: DateTime.utc_now(:second)]
      )

      assert EpicRework.send_again(card!(ctx.subcard)) == :in_place
      assert card!(ctx.epic).column_id == ctx.todo.id
    end
  end

  describe "an epic in progress with a rework and no job is named" do
    # The state the #3167 epic sat in: in progress, its subcard rejected
    # 25 minutes ago and back in its To Do, no job on either.
    setup ctx do
      # The job that took the epic has ended.
      job = Runners.claim(ctx.runner)
      assert job.card_id == ctx.epic.id

      :ok =
        Boards.Cards.move_card_to_index(card!(ctx.epic), ctx.doing, :top,
          actor: %{ctx.builder | via: "runner", job_id: job.id}
        )

      Repo.update_all(from(j in Job, where: j.id == ^job.id),
        set: [status: "done", finished_at: DateTime.add(DateTime.utc_now(:second), -30 * 60)]
      )

      at = DateTime.add(DateTime.utc_now(:second), -25 * 60)

      Repo.update_all(from(c in Card, where: c.id == ^ctx.subcard.id),
        set: [verify_state: "rejected", verify_at: at]
      )

      :ok
    end

    defp detect(board, changes \\ %{}) do
      StalledRework.detect(
        Context.new(Boards.get_board!(board.id), DateTime.utc_now(:second)),
        Settings.for(%{StalledRework.key() => changes}, StalledRework)
      )
    end

    test "Right now holds it as rework_stalled, saying why", ctx do
      row = Enum.find(Now.snapshot(ctx.board).in_progress, &(&1.id == ctx.epic.id))
      assert row.holds == "rework_stalled"

      assert row.why ==
               "##{ctx.subcard.id} was rejected, and no job is open on the epic or its rework"

      json = SlipdockWeb.API.NowJSON.card(row)
      assert json.holds == "rework_stalled"
      assert json.why =~ "##{ctx.subcard.id} was rejected"
    end

    test "an open build job on the epic, or a wait on the subcard, clears it", ctx do
      job =
        Repo.insert!(%Job{
          board_id: ctx.board.id,
          root_board_id: ctx.board.id,
          card_id: ctx.epic.id,
          pool: "loop",
          kind: "claude",
          prompt: "",
          status: "running"
        })

      row = Enum.find(Now.snapshot(ctx.board).in_progress, &(&1.id == ctx.epic.id))
      refute row.holds == "rework_stalled"
      assert row.why == nil
      assert detect(ctx.board) == []

      Repo.delete!(job)
      assert Map.keys(EpicRework.stalled([ctx.epic.id])) == [ctx.epic.id]

      {:ok, _} =
        Boards.Waits.open_wait(card!(ctx.subcard), Actor.web(ctx.owner), %{
          "needs" => "Which policy?"
        })

      assert EpicRework.stalled([ctx.epic.id]) == %{}
    end

    test "the health monitor finds it, says why, and sends the epic again", ctx do
      assert [f] = detect(ctx.board)
      assert f.card_id == ctx.epic.id
      assert f.subject["cards"] == [ctx.subcard.id]
      assert f.summary =~ "is in In Progress: ##{ctx.subcard.id} was rejected"
      assert f.summary =~ "(for 25 minutes)"

      # Too recent for the threshold: not yet.
      assert detect(ctx.board, %{"minutes" => 30}) == []

      assert {:fixed, "sent the epic again, to the top of To Do"} =
               StalledRework.resolve(%{data: f.data}, 1)

      assert card!(ctx.epic).column_id == ctx.todo.id
      assert open_jobs(ctx.rule) == [ctx.epic.id]
      assert detect(ctx.board) == []
    end
  end
end
