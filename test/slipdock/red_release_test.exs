defmodule Slipdock.RedReleaseTest do
  @moduledoc """
  A red release files its fix card and holds nothing (#2838, #3179): a
  failed deploy recorded on a batched tree is recorded, shown on the
  banner's line and files one critical fix card; Release now, the age cap,
  a queued follow-up and a critical merge still release, each warning with
  the failing run; the fix card's merge clears it and releases, and the
  fix card accepted with no code clears it and releases nothing (#2993).
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
    owner = user_fixture("red-release-#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Red releases", "code" => unique_code()}, owner: owner)

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
  # here: the window between a fix card being filed and named on the record.
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

  defp fix_cards(board),
    do:
      Repo.all(
        from(c in Card, where: c.board_id == ^board.id and c.origin == "release", order_by: c.id)
      )

  describe "a red release" do
    test "is recorded with the reason, stage and run, and files one critical fix card on top",
         ctx do
      first = merged!(ctx.todo, "First merged")
      second = merged!(ctx.todo, "Second merged")
      card_fixture(ctx.todo, %{"title" => "Already in To Do"})
      request = released!(ctx)
      assert Enum.sort(request.card_ids) == Enum.sort([first.id, second.id])

      deployment = red!(ctx.board, "test")

      red = Releases.red_release(ctx.board)
      assert red["reason"] == "the release failed at test"
      assert red["stage"] == "test"
      assert red["run_url"] == @run
      assert red["deployment_id"] == deployment.id
      assert Enum.sort(red["card_ids"]) == Enum.sort([first.id, second.id])

      [fix] = fix_cards(ctx.board)
      assert red["fix_card_id"] == fix.id
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

      assert Enum.any?(
               activity(ctx.board),
               &(&1 =~
                   "Release failed: the release failed at test (#{@run}); fix card ##{fix.id}. " <>
                     "Releases aren't held.")
             )

      # The status shows it, and so does the banner's line.
      status = Releases.status(ctx.board)
      assert status.red_release["fix_card_id"] == fix.id
      assert Releases.line(status) =~ "Last release failed: the release failed at test"
      assert Releases.line(status) =~ "fix card ##{fix.id}"

      # A view that links the run beside the reason takes the two apart (#2995).
      assert Releases.red_text(status) == "Last release failed: the release failed at test"
      assert Releases.line(status, red: false, awaiting: false) == "fix card ##{fix.id}"

      assert Releases.line(status, awaiting: false) ==
               "Last release failed: the release failed at test · fix card ##{fix.id}"
    end

    test "red_text and red_warning are nil while no red release stands", ctx do
      status = Releases.status(ctx.board)
      assert status.red_release == nil
      assert Releases.red_text(status) == nil
      assert Releases.red_warning(status) == nil
      assert Releases.red_warning(ctx.board) == nil
      assert Releases.line(status, red: false) == nil
    end

    test "the warning names the reason, the failing run and the fix card", ctx do
      red!(ctx.board, "deploy")
      [fix] = fix_cards(ctx.board)

      assert Releases.red_warning(ctx.board) ==
               "Warning: the last release failed: the release failed at deploy (#{@run}); " <>
                 "fix card ##{fix.id} is filed."

      assert Releases.red_warning(Releases.status(ctx.board)) == Releases.red_warning(ctx.board)
    end

    test "a record written as a hold before #3179 is read, with its held_at as failed_at", ctx do
      red!(ctx.board, "deploy")
      red = Releases.red_release(ctx.board)
      old = red |> Map.delete("failed_at") |> Map.put("held_at", "2026-11-12T10:00:00Z")
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [red_release: old])

      assert Releases.red_release(ctx.board)["failed_at"] == "2026-11-12T10:00:00Z"
      refute Map.has_key?(Releases.red_release(ctx.board), "held_at")
    end

    test "a sub-board's status and red release are its root's", ctx do
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card_fixture(ctx.todo), template)
      red!(ctx.board)
      assert Releases.red_release(sub)["stage"] == "test"
      assert Releases.status(sub).red_release == Releases.red_release(ctx.board)
    end

    test "a second red release keeps the first and files no second card", ctx do
      red!(ctx.board, "test")
      first = Releases.red_release(ctx.board)

      red!(ctx.board, "deploy")

      assert Releases.red_release(ctx.board) == first
      assert [_one] = fix_cards(ctx.board)

      assert List.last(activity(ctx.board)) =~
               "Another release failed; the first one's fix card stands"
    end

    test "one failure recorded in two steps fills in its own record: no second card, no 'again'",
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
      assert Releases.red_release(ctx.board)["reason"] == "the release failed"
      assert Releases.red_release(ctx.board)["run_url"] == nil
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

      red = Releases.red_release(ctx.board)
      assert red["reason"] == "the release failed at health"
      assert red["stage"] == "health"
      assert red["run_url"] == @run
      assert red["fix_card_id"] == fix.id

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

      red = Releases.red_release(ctx.board)
      assert outside.id in red["card_ids"]
      assert in_request.id in red["card_ids"]

      [fix] = fix_cards(ctx.board)
      assert fix.description =~ "- ##{outside.id} Named by the deploy only"
      assert fix.description =~ "- ##{in_request.id} In the request"
    end

    test "with no stage, no run and no card named, the record and its card say so", ctx do
      {:ok, _} =
        Deployments.start(ctx.board, %{
          environment: "production",
          sha: "fade0002",
          status: "failed",
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        })

      red = Releases.red_release(ctx.board)
      assert red["reason"] == "the release failed"
      assert red["card_ids"] == []

      [fix] = fix_cards(ctx.board)
      assert fix.title == "Red release: fix the release failure"
      assert fix.description =~ "no run named"
      assert fix.description =~ "No merged card was named in it."

      assert Releases.red_warning(red) ==
               "Warning: the last release failed: the release failed (no run named); " <>
                 "fix card ##{fix.id} is filed."

      assert fix.description =~ "Releases on this board aren't held"
      assert fix.description =~ "until this card merges, which releases"

      assert fix.description =~
               "accepted with no code, that clears the warning and releases nothing: " <>
                 "the batch goes at the next trigger"

      refute fix.description =~ "refused"
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

    test "a root with no lists records it with no fix card, and says only the reason and the run",
         ctx do
      Repo.delete_all(from(c in Slipdock.Boards.Column, where: c.board_id == ^ctx.board.id))
      red!(ctx.board)

      red = Releases.red_release(ctx.board)
      assert red["fix_card_id"] == nil
      assert fix_cards(ctx.board) == []

      assert Releases.red_warning(red) ==
               "Warning: the last release failed: the release failed at test (#{@run})."

      refute Releases.line(Releases.status(ctx.board)) =~ "fix card"
    end

    test "a root with no lists, its one failure recorded in two steps: the stage, no card, no crash",
         ctx do
      Repo.delete_all(from(c in Slipdock.Boards.Column, where: c.board_id == ^ctx.board.id))
      started = started!(ctx.board, "fade0003")
      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")
      assert Releases.red_release(ctx.board)["fix_card_id"] == nil

      {:ok, _} = failed_again!(ctx.board, "fade0003")

      red = Releases.red_release(ctx.board)
      assert red["stage"] == "health"
      assert red["run_url"] == @run
      assert red["fix_card_id"] == nil
      assert fix_cards(ctx.board) == []
      assert List.last(activity(ctx.board)) =~ "The failed release is recorded at health"
    end

    test "the failure recorded again while its fix card is filed: the card says it too", ctx do
      started = started!(ctx.board, "fade0004")
      board = ctx.board
      on_fix_card_insert(fn -> {:ok, _} = failed_again!(board, "fade0004") end)

      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")

      [fix] = fix_cards(ctx.board)
      red = Releases.red_release(ctx.board)
      assert red["stage"] == "health"
      assert red["fix_card_id"] == fix.id
      assert fix.title == "Red release: fix the health failure"
      assert fix.description =~ "[the failing run](#{@run})"
    end

    test "a red release cleared while its fix card is filed stays cleared", ctx do
      started = started!(ctx.board, "fade0005")
      board = ctx.board
      on_fix_card_insert(fn -> deployed!(board, "fade0005") end)

      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")

      assert [_fix] = fix_cards(ctx.board)
      assert Releases.red_release(ctx.board) == nil
    end

    test "a red release cleared and another recorded while the first fix card is filed " <>
           "keeps the second's card",
         ctx do
      started = started!(ctx.board, "fade0006")
      board = ctx.board

      on_fix_card_insert(fn ->
        deployed!(board, "fade0006")
        red!(board, "deploy")
      end)

      {:ok, _} = Deployments.finish(ctx.board, started.id, "failed")

      [_first, second] = fix_cards(ctx.board)
      red = Releases.red_release(ctx.board)
      assert red["stage"] == "deploy"
      assert red["fix_card_id"] == second.id
      refute red["deployment_id"] == started.id
    end

    test "starts the queued follow-up, warning with the failing run (#3179)", ctx do
      merged!(ctx.todo, "Waiting")
      request = released!(ctx)
      {:ok, :queued, queued} = Releases.request(ctx.board, "manual", "Eli")

      red!(ctx.board, "deploy")

      assert Repo.get!(Request, request.id).status == "failed"
      assert Repo.get!(Request, queued.id).status == "running"
      assert Releases.status(ctx.board).running.id == queued.id

      assert List.last(activity(ctx.board)) ==
               Releases.red_warning(ctx.board)

      assert List.last(activity(ctx.board)) =~ @run
      refute Enum.any?(activity(ctx.board), &(&1 =~ "dropped"))
    end
  end

  describe "after a red release (#3179)" do
    setup ctx do
      red!(ctx.board, "deploy")
      [fix] = fix_cards(ctx.board)
      %{fix: fix}
    end

    test "Release now releases, and the board's activity warns with the failing run", ctx do
      waiting = merged!(ctx.todo, "Waiting")
      assert {:ok, :started, request} = Releases.release_now(ctx.board, "Dana")
      assert waiting.id in request.card_ids

      warning = List.last(activity(ctx.board))
      assert warning == Releases.red_warning(ctx.board)
      assert warning =~ "the last release failed: the release failed at deploy (#{@run})"
      assert warning =~ "fix card ##{ctx.fix.id} is filed"

      # Still recorded and on the banner's line, with its fix card: releasing
      # doesn't clear it.
      assert Releases.red_release(ctx.board)["fix_card_id"] == ctx.fix.id
      assert Releases.line(Releases.status(ctx.board)) =~ "Last release failed"
    end

    test "the age cap releases, and warns", ctx do
      {:ok, _board} = Boards.update_board(ctx.board, %{"release_age_cap_hours" => 1})
      old = DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.truncate(:second)
      merged!(ctx.todo, "Old merge", completed_at: old)

      assert Releases.tick() == 1

      assert [%Request{status: "running", triggers: [%{"trigger" => "age_cap"}]}] =
               Repo.all(from(r in Request, where: r.status == "running"))

      assert List.last(activity(ctx.board)) == Releases.red_warning(ctx.board)
    end

    test "the age cap counts from the failed release's end, not the oldest merge", ctx do
      {:ok, _board} = Boards.update_board(ctx.board, %{"release_age_cap_hours" => 1})
      old = DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.truncate(:second)
      merged!(ctx.todo, "Old merge", completed_at: old)
      request = released!(ctx)
      red!(ctx.board, "test")
      assert Repo.get!(Request, request.id).status == "failed"

      # Just failed: the cap isn't refused, but nothing has waited an hour since.
      assert Releases.tick() == 0

      ended = DateTime.utc_now() |> DateTime.add(-2 * 3600) |> DateTime.truncate(:second)
      Repo.update_all(from(r in Request, where: r.id == ^request.id), set: [finished_at: ended])

      assert Releases.tick() == 1
      assert List.last(activity(ctx.board)) == Releases.red_warning(ctx.board)
    end

    test "a critical card that isn't the fix card releases, and warns", ctx do
      card = merged!(ctx.todo, "Urgent other", priority: "critical")

      assert {:ok, :started, request} = Releases.card_merged(card)
      assert [%{"trigger" => "critical"}] = request.triggers
      assert List.last(activity(ctx.board)) == Releases.red_warning(ctx.board)
    end

    test "the fix card merging clears it and releases", ctx do
      waiting = merged!(ctx.todo, "Waited behind the failure")

      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id),
        set: [
          completed: true,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          verify_state: "accepted",
          merge_sha: "fix0001"
        ]
      )

      assert {:ok, :started, request} = Releases.card_merged(Repo.get!(Card, ctx.fix.id))
      assert Releases.red_release(ctx.board) == nil
      assert [%{"trigger" => "critical"}] = request.triggers
      assert waiting.id in request.card_ids
      assert ctx.fix.id in request.card_ids

      assert Enum.any?(
               activity(ctx.board),
               &(&1 =~ "Red release cleared: fix card ##{ctx.fix.id} merged")
             )

      # Cleared before the request: it warns of nothing.
      refute Enum.any?(activity(ctx.board), &(&1 =~ "Warning:"))
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
      assert Releases.red_release(ctx.board) == nil
    end

    test "the fix card accepted with no code clears it and releases nothing (#2993)",
         ctx do
      waiting = merged!(ctx.todo, "Waited behind the failure")

      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id),
        set: [completed: true, verify_state: "accepted"]
      )

      Releases.subscribe(ctx.board)
      assert Releases.card_merged(Repo.get!(Card, ctx.fix.id)) == :ok
      assert Releases.red_release(ctx.board) == nil
      assert Repo.aggregate(Request, :count) == 0
      assert Releases.status(ctx.board).running == nil
      # An open board's banner hears it go.
      board_id = ctx.board.id
      assert_receive {:release_changed, ^board_id}

      line = List.last(activity(ctx.board))
      assert line =~ "Red release cleared: fix card ##{ctx.fix.id} accepted with no code"
      assert line =~ "Nothing was released: the batch goes at the next trigger."

      # The batch goes at the next trigger, with no warning now.
      assert {:ok, :started, request} = Releases.release_now(ctx.board, "Dana")
      assert waiting.id in request.card_ids
    end

    test "the fix card accepted with a no-code reason clears only, whatever commit its " <>
           "verifier named",
         ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id),
        set: [
          completed: true,
          verify_state: "accepted",
          verify_commit: "abc0001",
          evidence_no_code: "the cause was a credential, outside the repository"
        ]
      )

      assert Releases.card_merged(Repo.get!(Card, ctx.fix.id)) == :ok
      assert Releases.red_release(ctx.board) == nil
      assert Repo.aggregate(Request, :count) == 0
    end

    test "the fix card not accepted clears nothing", ctx do
      assert Releases.card_merged(Repo.get!(Card, ctx.fix.id)) == :ok
      assert Releases.red_release(ctx.board)["fix_card_id"] == ctx.fix.id
      refute Enum.any?(activity(ctx.board), &(&1 =~ "Red release cleared"))
    end

    test "another card accepted with no code clears nothing", ctx do
      other = card_fixture(ctx.todo, %{"title" => "A sweep", "priority" => "critical"})

      Repo.update_all(from(c in Card, where: c.id == ^other.id),
        set: [completed: true, verify_state: "accepted"]
      )

      assert Releases.card_merged(Repo.get!(Card, other.id)) == :ok
      assert Releases.red_release(ctx.board)["fix_card_id"] == ctx.fix.id
      assert Repo.aggregate(Request, :count) == 0
    end

    test "a tree set back to releasing on merge: the fix card accepted with no code is left alone",
         ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})

      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id),
        set: [completed: true, verify_state: "accepted"]
      )

      assert Releases.card_merged(Repo.get!(Card, ctx.fix.id)) == :ok
      refute Enum.any?(activity(ctx.board), &(&1 =~ "Red release cleared"))
    end

    test "there is no lifting it by hand: the hold's door is gone", _ctx do
      refute function_exported?(Releases, :lift_hold, 2)
      refute function_exported?(Releases, :hold, 1)
    end
  end

  describe "a succeeded deploy past the red release (#2996)" do
    setup ctx do
      failed = red!(ctx.board, "deploy")
      [fix] = fix_cards(ctx.board)
      %{failed: failed, fix: fix}
    end

    defp comments(card),
      do:
        Repo.all(from(c in Slipdock.Boards.Comment, where: c.card_id == ^card.id, select: c.body))

    test "the failed run rerun: the same sha deployed clears it, archives the unstarted fix card " <>
           "and says so",
         ctx do
      # A rerun's deploy job starts its own row and finishes it succeeded.
      started = started!(ctx.board, ctx.failed.sha)
      {:ok, _} = Deployments.finish(ctx.board, started.id, "succeeded")

      assert Releases.red_release(ctx.board) == nil
      assert Releases.line(Releases.status(ctx.board)) == nil

      said = List.last(activity(ctx.board))
      assert said =~ "Red release cleared: `#{String.slice(ctx.failed.sha, 0, 7)}` deployed"
      assert said =~ "to production, at the failed sha"
      assert said =~ "(the release failed at deploy)"
      assert said =~ "Fix card ##{ctx.fix.id} was archived: nothing had started on it."

      fix = Repo.get!(Card, ctx.fix.id)
      assert fix.archived_at
      assert [note] = comments(fix)
      assert note =~ "**Red release cleared.**"
      assert note =~ "so it is archived"

      # Releases run again, and cleared is cleared: nothing asks.
      assert Repo.aggregate(Request, :count) == 0
      assert {:ok, :started, _} = Releases.release_now(ctx.board, "Dana")
    end

    test "a later release, whose commits include the failed sha, clears it as past it", ctx do
      deployed!(ctx.board, "abcdef1234", %{
        commits: [
          %{sha: "abcdef1234", subject: "The fix"},
          %{sha: ctx.failed.sha, subject: "The release that failed"}
        ]
      })

      assert Releases.red_release(ctx.board) == nil

      assert List.last(activity(ctx.board)) =~
               "`abcdef1` deployed to production (#{@run}), past it"
    end

    test "an abbreviated sha of the failed one clears it", ctx do
      full = ctx.failed.sha <> "00"

      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [red_release: %{Releases.red_release(ctx.board) | "sha" => full}]
      )

      deployed!(ctx.board, ctx.failed.sha)
      assert Releases.red_release(ctx.board) == nil
    end

    test "a fix card already under way is told and left open", ctx do
      doing = Enum.find(ctx.board.columns, &Slipdock.Flow.doing_list?/1)
      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id), set: [column_id: doing.id])

      deployed!(ctx.board, ctx.failed.sha)

      assert Releases.red_release(ctx.board) == nil
      fix = Repo.get!(Card, ctx.fix.id)
      assert fix.archived_at == nil
      assert [note] = comments(fix)
      assert note =~ "isn't needed to clear it any more"

      assert List.last(activity(ctx.board)) =~
               "Fix card ##{ctx.fix.id} is under way, so it was told and left open."
    end

    test "a fix card in the ready list with a job queued for it is under way too", ctx do
      working_job_fixture(ctx.fix, status: "queued")

      deployed!(ctx.board, ctx.failed.sha)

      assert Repo.get!(Card, ctx.fix.id).archived_at == nil
      assert List.last(activity(ctx.board)) =~ "is under way"
    end

    test "a fix card already done is left alone, and the line says nothing of it", ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.fix.id), set: [completed: true])

      deployed!(ctx.board, ctx.failed.sha)

      assert Releases.red_release(ctx.board) == nil
      assert comments(Repo.get!(Card, ctx.fix.id)) == []
      refute List.last(activity(ctx.board)) =~ "Fix card"
    end

    test "an older or unrelated sha leaves it standing", ctx do
      deployed!(ctx.board, "0123456789", %{commits: [%{sha: "0123456789", subject: "Older"}]})

      assert Releases.red_release(ctx.board)["fix_card_id"] == ctx.fix.id
      assert Repo.get!(Card, ctx.fix.id).archived_at == nil
      refute Enum.any?(activity(ctx.board), &(&1 =~ "Red release cleared"))
    end

    test "the failed sha deployed to another environment leaves it standing", ctx do
      deployed!(ctx.board, ctx.failed.sha, %{environment: "staging"})
      assert Releases.red_release(ctx.board)
    end

    test "a deploy of the failed sha still started, or backfilled, leaves it standing", ctx do
      started!(ctx.board, ctx.failed.sha)

      deployed!(ctx.board, "abcdef5678", %{
        source: "backfill",
        commits: [%{sha: ctx.failed.sha, subject: "The release that failed"}]
      })

      assert Releases.red_release(ctx.board)
    end

    test "a red release with no sha is cleared only by its fix card", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [red_release: %{Releases.red_release(ctx.board) | "sha" => nil}]
      )

      deployed!(ctx.board, ctx.failed.sha)
      assert Releases.red_release(ctx.board)
    end

    test "a red release with an empty sha is not cleared by an unrelated deploy", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [red_release: %{Releases.red_release(ctx.board) | "sha" => ""}]
      )

      deployed!(ctx.board, "0123456789", %{commits: [%{sha: "0123456789", subject: "Older"}]})

      assert Releases.red_release(ctx.board)
      refute Enum.any?(activity(ctx.board), &(&1 =~ "Red release cleared"))
    end

    # The failed deploy's row can be gone (its sub-board deleted): the record
    # can't say which environment it was, so the failed sha anywhere clears it.
    for {label, gone} <- [{"no deploy row named", nil}, {"its deploy row gone", -1}] do
      test "a red release with #{label} is cleared by the failed sha deployed", ctx do
        Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
          set: [
            red_release: %{Releases.red_release(ctx.board) | "deployment_id" => unquote(gone)}
          ]
        )

        deployed!(ctx.board, ctx.failed.sha)

        assert Releases.red_release(ctx.board) == nil
        assert List.last(activity(ctx.board)) =~ "Red release cleared"
      end
    end

    # The fix card failed to file, or the deploy landed before it was named.
    test "a red release with no fix card is cleared, and the line names none", ctx do
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [red_release: %{Releases.red_release(ctx.board) | "fix_card_id" => nil}]
      )

      started = started!(ctx.board, ctx.failed.sha)
      assert {:ok, _} = Deployments.finish(ctx.board, started.id, "succeeded")

      assert Releases.red_release(ctx.board) == nil
      said = List.last(activity(ctx.board))
      assert said =~ "Red release cleared"
      refute said =~ "Fix card"
      assert Repo.get!(Card, ctx.fix.id).archived_at == nil
    end
  end

  describe "the fix card accepted through verified work (#2993)" do
    setup ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{
          "verify_work" => true,
          "evidence_required" => true,
          "ship_via" => "pull_request"
        })

      red!(board, "deploy")
      [fix] = fix_cards(board)

      agent = fn name ->
        %{
          Slipdock.Actor.unknown()
          | kind: "agent",
            via: "api",
            user_id: ctx.owner.id,
            agent: name
        }
      end

      %{board: board, fix: fix, builder: agent.("builder"), checker: agent.("checker")}
    end

    test "completed --no-code and accepted: it clears, nothing is asked, the card is done",
         ctx do
      waiting = merged!(ctx.todo, "Waited behind the failure")

      {:ok, %{verify_state: "pending"}} =
        Boards.Cards.update_card(
          Repo.get!(Card, ctx.fix.id),
          %{
            "completed" => true,
            "evidence" => "the trust credential was renewed",
            "evidence_no_code" => "the cause was a credential, outside the repository"
          },
          actor: ctx.builder
        )

      # Submitted, not accepted: it still stands.
      assert Releases.red_release(ctx.board)["fix_card_id"] == ctx.fix.id

      assert {:ok, card} =
               Slipdock.Verified.decide(
                 Repo.get!(Card, ctx.fix.id),
                 "accept",
                 %{},
                 ctx.checker,
                 ctx.owner
               )

      assert card.completed
      assert card.verify_state == "accepted"
      assert Releases.red_release(ctx.board) == nil
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.all(from(j in Job, where: j.kind == "release")) == []

      assert List.last(activity(ctx.board)) =~
               "Red release cleared: fix card ##{ctx.fix.id} accepted with no code"

      assert [%{id: id}] = Releases.status(ctx.board).awaiting
      assert id == waiting.id
    end
  end

  describe "no red release" do
    test "a release job that failed to fire", ctx do
      {:ok, :started, _request} = Releases.request(ctx.board, "manual", "Dana")
      %Job{id: id} = Runners.claim(ctx.runner)
      {:ok, _job} = Runners.finish(ctx.runner, id, %{exit: "2", status: "failed"})

      assert Releases.red_release(ctx.board) == nil
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

      assert Releases.red_release(ctx.board) == nil
      assert fix_cards(ctx.board) == []
    end

    test "a failed deploy on a board that releases on merge", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      red!(board)
      assert Repo.get!(Board, board.id).red_release == nil
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

      assert Releases.red_release(ctx.board) == nil
      assert Releases.line(Releases.status(ctx.board)) == nil
    end
  end
end
