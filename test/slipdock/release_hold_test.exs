defmodule Slipdock.ReleaseHoldTest do
  @moduledoc """
  A red release holds releases (#2838): a failed deploy recorded on a
  batched tree holds its releases and files one critical fix card; held,
  Release now and the age cap are refused and a critical merge asks for
  nothing; the fix card's merge lifts the hold and releases, and the owner
  can lift it by hand, which releases nothing.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments, Releases, Repo, Runners}
  alias Slipdock.Boards.{Activity, Board, Card}
  alias Slipdock.Releases.Request
  alias Slipdock.Runners.Job

  @run "https://github.com/example/app/actions/runs/77"

  setup do
    owner = user_fixture("release-hold-#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Release holds", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{"delivery_metrics" => true, "release_mode" => "batched"})

    {:ok, runner, _token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    runner = Runners.report_kinds(runner, "merge,release")
    [_backlog, todo | _] = board.columns
    %{owner: owner, board: board, todo: todo, runner: runner}
  end

  defp merged!(column, title, fields \\ []), do: merged_card_fixture(column, title, fields)

  defp activity(board) do
    Repo.all(
      from(a in Activity,
        where: a.board_id == ^board.id and a.kind == "release",
        order_by: a.id,
        select: a.message
      )
    )
  end

  # A release started and its job done, as a runner leaves it: the request
  # waits for the deploy.
  defp released!(ctx) do
    {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
    %Job{id: id} = Runners.claim(ctx.runner)
    {:ok, _job} = Runners.finish(ctx.runner, id, %{exit: "0", status: "done"})
    request
  end

  defp red!(board, stage \\ "test", extra \\ %{}) do
    {:ok, failed} =
      Deployments.record_failure(
        board,
        Map.merge(
          %{
            environment: "production",
            sha: "feed#{System.unique_integer([:positive])}",
            stage: stage,
            run_url: @run
          },
          extra
        )
      )

    failed
  end

  defp started!(board, sha) do
    {:ok, started} =
      Deployments.start(board, %{
        environment: "production",
        sha: sha,
        status: "started",
        started_at: DateTime.utc_now()
      })

    started
  end

  # release.yml's record-failure job: the same row, with the stage and the run.
  defp failed_again!(board, sha) do
    Deployments.record_failure(board, %{
      environment: "production",
      sha: sha,
      stage: "health",
      run_url: @run
    })
  end

  # Runs `fun` once, in this process, just after the first card is inserted
  # here: the window between a fix card being filed and named on the hold.
  defp on_fix_card_insert(fun) do
    test = self()
    id = "fix-card-insert-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:slipdock, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and not Process.get(id, false) and
             String.starts_with?(meta.query, ~s(INSERT INTO "cards")) do
          Process.put(id, true)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp fix_cards(board),
    do:
      Repo.all(
        from(c in Card, where: c.board_id == ^board.id and c.origin == "release", order_by: c.id)
      )

  describe "a red release" do
    test "holds the tree with the reason, stage and run, and files one critical fix card on top",
         ctx do
      first = merged!(ctx.todo, "First merged")
      second = merged!(ctx.todo, "Second merged")
      card_fixture(ctx.todo, %{"title" => "Already in To Do"})
      request = released!(ctx)
      assert Enum.sort(request.card_ids) == Enum.sort([first.id, second.id])

      deployment = red!(ctx.board, "test")

      hold = Releases.hold(ctx.board)
      assert hold["reason"] == "the release failed at test"
      assert hold["stage"] == "test"
      assert hold["run_url"] == @run
      assert hold["deployment_id"] == deployment.id
      assert Enum.sort(hold["card_ids"]) == Enum.sort([first.id, second.id])

      [fix] = fix_cards(ctx.board)
      assert hold["fix_card_id"] == fix.id
      assert fix.priority == "critical"
      assert fix.column_id == ctx.todo.id
      assert fix.title == "Red release: fix the test failure"
      assert fix.description =~ "[the failing run](#{@run})"
      assert fix.description =~ "- ##{first.id} First merged"
      assert fix.description =~ "- ##{second.id} Second merged"

      # On top of the ready list.
      [top | _] =
        Repo.all(
          from(c in Card,
            where: c.column_id == ^ctx.todo.id and is_nil(c.archived_at) and not c.completed,
            order_by: c.position
          )
        )

      assert top.id == fix.id

      # The request failed, and the board says why.
      assert Repo.get!(Request, request.id).status == "failed"
      assert Enum.any?(activity(ctx.board), &(&1 =~ "Releases held: the release failed at test"))

      # The status shows it, and so does the banner's line.
      status = Releases.status(ctx.board)
      assert status.hold["fix_card_id"] == fix.id
      assert Releases.line(status) =~ "Releases held: the release failed at test"
      assert Releases.line(status) =~ "fix card ##{fix.id}"

      # A view that links the run beside the reason takes the two apart (#2995).
      assert Releases.hold_text(status) == "Releases held: the release failed at test"
      assert Releases.line(status, hold: false, awaiting: false) == "fix card ##{fix.id}"

      assert Releases.line(status, awaiting: false) ==
               "Releases held: the release failed at test · fix card ##{fix.id}"
    end

    test "hold_text is nil while releases aren't held", ctx do
      status = Releases.status(ctx.board)
      assert status.hold == nil
      assert Releases.hold_text(status) == nil
      assert Releases.line(status, hold: false) == nil
    end

    test "a sub-board's status and hold are its root's", ctx do
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card_fixture(ctx.todo), template)
      red!(ctx.board)
      assert Releases.hold(sub)["stage"] == "test"
      assert Releases.status(sub).hold == Releases.hold(ctx.board)
    end

    test "a second red release keeps the first hold and files no second card", ctx do
      red!(ctx.board, "test")
      first = Releases.hold(ctx.board)

      red!(ctx.board, "deploy")

      assert Releases.hold(ctx.board) == first
      assert [_one] = fix_cards(ctx.board)
      assert List.last(activity(ctx.board)) =~ "Another release failed; the hold stays"
    end

    test "one failure recorded in two steps fills in its own hold: no second card, no 'again'",
         ctx do
      merged!(ctx.todo, "In the batch")
      released!(ctx)

      # release.yml's deploy job: started, then finished failed, with no stage.
      {:ok, started} =
        Deployments.start(ctx.board, %{
          environment: "production",
          sha: "fade0001",
          status: "started",
          started_at: DateTime.utc_now()
        })

      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")
      assert Releases.hold(ctx.board)["reason"] == "the release failed"
      assert Releases.hold(ctx.board)["run_url"] == nil
      [fix] = fix_cards(ctx.board)
      assert fix.title == "Red release: fix the release failure"
      assert fix.description =~ "no run named"

      # Its record-failure job: the same row, now with the stage and the run.
      {:ok, again} =
        Deployments.record_failure(ctx.board, %{
          environment: "production",
          sha: "fade0001",
          stage: "health",
          run_url: @run
        })

      assert again.id == started.id

      hold = Releases.hold(ctx.board)
      assert hold["reason"] == "the release failed at health"
      assert hold["stage"] == "health"
      assert hold["run_url"] == @run
      assert hold["fix_card_id"] == fix.id

      assert [fix] = fix_cards(ctx.board)
      assert fix.title == "Red release: fix the health failure"
      assert fix.description =~ "[the failing run](#{@run})"

      refute Enum.any?(activity(ctx.board), &(&1 =~ "Another release failed"))
      assert List.last(activity(ctx.board)) =~ "The failed release is recorded at health"
    end

    test "names the cards the failed deploy itself names, beside its request's", ctx do
      in_request = merged!(ctx.todo, "In the request")
      released!(ctx)
      outside = merged!(ctx.todo, "Named by the deploy only")

      red!(ctx.board, "deploy", %{
        commits: [%{"sha" => "abc1234def5678", "subject" => "feat ##{outside.id}"}]
      })

      hold = Releases.hold(ctx.board)
      assert outside.id in hold["card_ids"]
      assert in_request.id in hold["card_ids"]

      [fix] = fix_cards(ctx.board)
      assert fix.description =~ "- ##{outside.id} Named by the deploy only"
      assert fix.description =~ "- ##{in_request.id} In the request"
    end

    test "with no stage, no run and no card named, the hold and its card say so", ctx do
      {:ok, _} =
        Deployments.start(ctx.board, %{
          environment: "production",
          sha: "fade0002",
          status: "failed",
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        })

      hold = Releases.hold(ctx.board)
      assert hold["reason"] == "the release failed"
      assert hold["card_ids"] == []

      [fix] = fix_cards(ctx.board)
      assert fix.title == "Red release: fix the release failure"
      assert fix.description =~ "no run named"
      assert fix.description =~ "No merged card was named in it."

      assert Releases.held_text(hold) ==
               "the release failed; fix card ##{fix.id} releases when it merges, " <>
                 "or the board's owner lifts the hold"
    end

    test "a root with no ready list files the card in its first list", ctx do
      Repo.update_all(
        from(c in Slipdock.Boards.Column, where: c.board_id == ^ctx.board.id),
        set: [category: nil]
      )

      first = hd(Boards.get_board!(ctx.board.id).columns)
      red!(ctx.board)

      [fix] = fix_cards(ctx.board)
      assert fix.column_id == first.id
    end

    test "a root with no lists holds with no fix card, and says only the reason and the run",
         ctx do
      Repo.delete_all(from(c in Slipdock.Boards.Column, where: c.board_id == ^ctx.board.id))
      red!(ctx.board)

      hold = Releases.hold(ctx.board)
      assert hold["fix_card_id"] == nil
      assert fix_cards(ctx.board) == []

      assert Releases.held_text(hold) ==
               "the release failed at test (#{@run}), or the board's owner lifts the hold"

      refute Releases.line(Releases.status(ctx.board)) =~ "fix card"
    end

    test "a root with no lists, its one failure recorded in two steps: the stage, no card, no crash",
         ctx do
      Repo.delete_all(from(c in Slipdock.Boards.Column, where: c.board_id == ^ctx.board.id))
      started = started!(ctx.board, "fade0003")
      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")
      assert Releases.hold(ctx.board)["fix_card_id"] == nil

      {:ok, _} = failed_again!(ctx.board, "fade0003")

      hold = Releases.hold(ctx.board)
      assert hold["stage"] == "health"
      assert hold["run_url"] == @run
      assert hold["fix_card_id"] == nil
      assert fix_cards(ctx.board) == []
      assert List.last(activity(ctx.board)) =~ "The failed release is recorded at health"
    end

    test "the failure recorded again while its fix card is filed: the card says it too", ctx do
      started = started!(ctx.board, "fade0004")
      board = ctx.board
      on_fix_card_insert(fn -> {:ok, _} = failed_again!(board, "fade0004") end)

      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")

      [fix] = fix_cards(ctx.board)
      hold = Releases.hold(ctx.board)
      assert hold["stage"] == "health"
      assert hold["fix_card_id"] == fix.id
      assert fix.title == "Red release: fix the health failure"
      assert fix.description =~ "[the failing run](#{@run})"
    end

    test "a hold lifted while its fix card is filed stays lifted", ctx do
      started = started!(ctx.board, "fade0005")
      board = ctx.board
      on_fix_card_insert(fn -> {:ok, _} = Releases.lift_hold(board, "Dana") end)

      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")

      assert [_fix] = fix_cards(ctx.board)
      assert Releases.hold(ctx.board) == nil
    end

    test "a hold lifted and held again by another failure while the first fix card is filed " <>
           "keeps the second's card",
         ctx do
      started = started!(ctx.board, "fade0006")
      board = ctx.board

      on_fix_card_insert(fn ->
        {:ok, _} = Releases.lift_hold(board, "Dana")
        red!(board, "deploy")
      end)

      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")

      [_first, second] = fix_cards(ctx.board)
      hold = Releases.hold(ctx.board)
      assert hold["stage"] == "deploy"
      assert hold["fix_card_id"] == second.id
      refute hold["deployment_id"] == started.id
    end

    test "drops the queued follow-up rather than start it", ctx do
      merged!(ctx.todo, "Waiting")
      request = released!(ctx)
      {:ok, :queued, queued} = Releases.request(ctx.board, "manual", "Eli")

      red!(ctx.board, "deploy")

      assert Repo.get!(Request, request.id).status == "failed"
      assert Repo.get(Request, queued.id) == nil
      assert Releases.status(ctx.board).running == nil
      assert Enum.any?(activity(ctx.board), &(&1 =~ "Queued release dropped: releases are held"))
    end
  end

  describe "held" do
    setup ctx do
      red!(ctx.board, "deploy")
      [fix] = fix_cards(ctx.board)
      %{fix: fix}
    end

    test "Release now is refused, saying why with the run and the fix card", ctx do
      assert {:error, {:held, hold}} = Releases.release_now(ctx.board, "Dana")
      text = Releases.refusal({:held, hold})
      assert text =~ "releases are held: the release failed at deploy"
      assert text =~ @run
      assert text =~ "fix card ##{ctx.fix.id} releases when it merges"
      assert Repo.aggregate(Request, :count) == 0
    end

    test "the age cap asks for nothing", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"release_age_cap_hours" => 1})
      old = DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.truncate(:second)
      merged!(ctx.todo, "Old merge", completed_at: old)

      assert Releases.tick() == 0
      assert Repo.aggregate(Request, :count) == 0
      assert {:error, {:held, _}} = Releases.request(board, "age_cap", "test")
    end

    test "a critical card that isn't the fix card asks for nothing, and the board says so",
         ctx do
      card = merged!(ctx.todo, "Urgent other", priority: "critical")

      assert {:error, {:held, _}} = Releases.card_merged(card)
      assert Repo.aggregate(Request, :count) == 0

      assert List.last(activity(ctx.board)) =~
               "Not released: critical card ##{card.id} Urgent other merged, but releases are held"
    end

    test "the fix card merging lifts the hold and releases", ctx do
      waiting = merged!(ctx.todo, "Waited behind the hold")

      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id),
        set: [
          completed: true,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          verify_state: "accepted",
          merge_sha: "fix0001"
        ]
      )

      assert {:ok, :started, request} = Releases.card_merged(Repo.get!(Card, ctx.fix.id))
      assert Releases.hold(ctx.board) == nil
      assert [%{"trigger" => "critical"}] = request.triggers
      assert waiting.id in request.card_ids
      assert ctx.fix.id in request.card_ids
      assert Enum.any?(activity(ctx.board), &(&1 =~ "lifted: fix card ##{ctx.fix.id} merged"))
    end

    test "the fix card asks even when a person made it less than critical", ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id),
        set: [
          priority: "high",
          completed: true,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          verify_state: "accepted",
          merge_sha: "fix0002"
        ]
      )

      assert {:ok, :started, _request} = Releases.card_merged(Repo.get!(Card, ctx.fix.id))
      assert Releases.hold(ctx.board) == nil
    end

    test "the fix card accepted with nothing merged lifts nothing", ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id),
        set: [completed: true, verify_state: "accepted"]
      )

      assert Releases.card_merged(Repo.get!(Card, ctx.fix.id)) == :ok
      assert Releases.hold(ctx.board)["fix_card_id"] == ctx.fix.id
    end

    test "lifting it by hand releases nothing; lifting again is refused", ctx do
      merged!(ctx.todo, "Waiting")
      assert {:ok, hold} = Releases.lift_hold(ctx.board, "Dana")
      assert hold["fix_card_id"] == ctx.fix.id
      assert Releases.hold(ctx.board) == nil
      assert Repo.aggregate(Request, :count) == 0
      assert List.last(activity(ctx.board)) =~ "Release hold lifted by Dana"
      assert List.last(activity(ctx.board)) =~ "Nothing was released."

      assert Releases.lift_hold(ctx.board, "Dana") == {:error, :not_held}
      assert Releases.refusal(:not_held) == "this board's releases aren't held"

      # Released again as before.
      assert {:ok, :started, _} = Releases.release_now(ctx.board, "Dana")
    end
  end

  describe "a succeeded deploy past the hold (#2996)" do
    setup ctx do
      held = red!(ctx.board, "deploy")
      [fix] = fix_cards(ctx.board)
      %{held: held, fix: fix}
    end

    defp deployed!(board, sha, extra \\ %{}) do
      {:ok, deployment} =
        Deployments.start(
          board,
          Map.merge(
            %{
              environment: "production",
              sha: sha,
              status: "succeeded",
              run_url: @run,
              started_at: DateTime.utc_now(),
              finished_at: DateTime.utc_now()
            },
            extra
          )
        )

      deployment
    end

    defp comments(card),
      do:
        Repo.all(from(c in Slipdock.Boards.Comment, where: c.card_id == ^card.id, select: c.body))

    test "the failed run rerun: the same sha deployed lifts it, archives the unstarted fix card " <>
           "and says so",
         ctx do
      # A rerun's deploy job starts its own row and finishes it succeeded.
      started = started!(ctx.board, ctx.held.sha)
      {:ok, _} = Deployments.finish(ctx.board, started.id, "succeeded")

      assert Releases.hold(ctx.board) == nil
      assert Releases.line(Releases.status(ctx.board)) == nil

      said = List.last(activity(ctx.board))
      assert said =~ "Release hold lifted: `#{String.slice(ctx.held.sha, 0, 7)}` deployed"
      assert said =~ "to production, at the held sha"
      assert said =~ "(the release failed at deploy)"
      assert said =~ "Fix card ##{ctx.fix.id} was archived: nothing had started on it."

      fix = Repo.get!(Card, ctx.fix.id)
      assert fix.archived_at
      assert [note] = comments(fix)
      assert note =~ "**Release hold lifted.**"
      assert note =~ "so it is archived"

      # Releases run again, and lifted is lifted: nothing asks.
      assert Repo.aggregate(Request, :count) == 0
      assert {:ok, :started, _} = Releases.release_now(ctx.board, "Dana")
    end

    test "a later release, whose commits include the held sha, lifts it as past it", ctx do
      deployed!(ctx.board, "abcdef1234", %{
        commits: [
          %{sha: "abcdef1234", subject: "The fix"},
          %{sha: ctx.held.sha, subject: "The release that failed"}
        ]
      })

      assert Releases.hold(ctx.board) == nil

      assert List.last(activity(ctx.board)) =~
               "`abcdef1` deployed to production (#{@run}), past it"
    end

    test "an abbreviated sha of the held one lifts it", ctx do
      full = ctx.held.sha <> "00"

      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [release_hold: %{Releases.hold(ctx.board) | "sha" => full}]
      )

      deployed!(ctx.board, ctx.held.sha)
      assert Releases.hold(ctx.board) == nil
    end

    test "a fix card already under way is told and left open", ctx do
      doing = Enum.find(ctx.board.columns, &Slipdock.Flow.doing_list?/1)
      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id), set: [column_id: doing.id])

      deployed!(ctx.board, ctx.held.sha)

      assert Releases.hold(ctx.board) == nil
      fix = Repo.get!(Card, ctx.fix.id)
      assert fix.archived_at == nil
      assert [note] = comments(fix)
      assert note =~ "isn't needed to lift it any more"

      assert List.last(activity(ctx.board)) =~
               "Fix card ##{ctx.fix.id} is under way, so it was told and left open."
    end

    test "a fix card in the ready list with a job queued for it is under way too", ctx do
      working_job_fixture(ctx.fix, status: "queued")

      deployed!(ctx.board, ctx.held.sha)

      assert Repo.get!(Card, ctx.fix.id).archived_at == nil
      assert List.last(activity(ctx.board)) =~ "is under way"
    end

    test "a fix card already done is left alone, and the line says nothing of it", ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id), set: [completed: true])

      deployed!(ctx.board, ctx.held.sha)

      assert Releases.hold(ctx.board) == nil
      assert comments(Repo.get!(Card, ctx.fix.id)) == []
      refute List.last(activity(ctx.board)) =~ "Fix card"
    end

    test "an older or unrelated sha leaves it held", ctx do
      deployed!(ctx.board, "0123456789", %{commits: [%{sha: "0123456789", subject: "Older"}]})

      assert Releases.hold(ctx.board)["fix_card_id"] == ctx.fix.id
      assert Repo.get!(Card, ctx.fix.id).archived_at == nil
      refute Enum.any?(activity(ctx.board), &(&1 =~ "Release hold lifted"))
    end

    test "the held sha deployed to another environment leaves it held", ctx do
      deployed!(ctx.board, ctx.held.sha, %{environment: "staging"})
      assert Releases.hold(ctx.board)
    end

    test "a deploy of the held sha still started, or backfilled, leaves it held", ctx do
      started!(ctx.board, ctx.held.sha)

      deployed!(ctx.board, "abcdef5678", %{
        source: "backfill",
        commits: [%{sha: ctx.held.sha, subject: "The release that failed"}]
      })

      assert Releases.hold(ctx.board)
    end

    test "a hold with no sha is lifted only by its fix card or by hand", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [release_hold: %{Releases.hold(ctx.board) | "sha" => nil}]
      )

      deployed!(ctx.board, ctx.held.sha)
      assert Releases.hold(ctx.board)
    end

    test "a hold with an empty sha is not lifted by an unrelated deploy", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [release_hold: %{Releases.hold(ctx.board) | "sha" => ""}]
      )

      deployed!(ctx.board, "0123456789", %{commits: [%{sha: "0123456789", subject: "Older"}]})

      assert Releases.hold(ctx.board)
      refute Enum.any?(activity(ctx.board), &(&1 =~ "Release hold lifted"))
    end

    # The failed deploy's row can be gone (its sub-board deleted): the hold
    # can't say which environment it was, so the held sha anywhere lifts it.
    for {label, gone} <- [{"no deploy row named", nil}, {"its deploy row gone", -1}] do
      test "a hold with #{label} is lifted by the held sha deployed", ctx do
        Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
          set: [release_hold: %{Releases.hold(ctx.board) | "deployment_id" => unquote(gone)}]
        )

        deployed!(ctx.board, ctx.held.sha)

        assert Releases.hold(ctx.board) == nil
        assert List.last(activity(ctx.board)) =~ "Release hold lifted"
      end
    end

    # The fix card failed to file, or the deploy landed before it was named.
    test "a hold with no fix card is lifted, and the line names none", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [release_hold: %{Releases.hold(ctx.board) | "fix_card_id" => nil}]
      )

      started = started!(ctx.board, ctx.held.sha)
      assert {:ok, _} = Deployments.finish(ctx.board, started.id, "succeeded")

      assert Releases.hold(ctx.board) == nil
      said = List.last(activity(ctx.board))
      assert said =~ "Release hold lifted"
      refute said =~ "Fix card"
      assert Repo.get!(Card, ctx.fix.id).archived_at == nil
    end
  end

  describe "holds nothing" do
    test "a release job that failed to fire", ctx do
      {:ok, :started, _request} = Releases.request(ctx.board, "manual", "Dana")
      %Job{id: id} = Runners.claim(ctx.runner)
      {:ok, _job} = Runners.finish(ctx.runner, id, %{exit: "2", status: "failed"})

      assert Releases.hold(ctx.board) == nil
      assert fix_cards(ctx.board) == []
    end

    test "a backfilled failed deploy", ctx do
      {:ok, _} =
        Deployments.start(ctx.board, %{
          environment: "production",
          sha: "bacc0001",
          status: "failed",
          source: "backfill",
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        })

      assert Releases.hold(ctx.board) == nil
      assert fix_cards(ctx.board) == []
    end

    test "a failed deploy on a board that releases on merge", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      red!(board)
      assert Repo.get!(Board, board.id).release_hold == nil
      assert fix_cards(board) == []
    end

    test "a succeeded deploy", ctx do
      {:ok, _} =
        Deployments.start(ctx.board, %{
          environment: "production",
          sha: "cccc0001",
          status: "succeeded",
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        })

      assert Releases.hold(ctx.board) == nil
      assert Releases.line(Releases.status(ctx.board)) == nil
    end
  end
end
