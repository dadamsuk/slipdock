defmodule Slipdock.ReleaseRequestsTest do
  @moduledoc """
  Release requests (#2835): on a batched tree a release is asked for by a
  critical card merging, *Release now* or the age cap; one runs at a time,
  a trigger during one queues a single follow-up and more join it; a
  request starts a card-less `release` job for the pool that merges, which
  lanes never hold and only a runner taking `release` is handed; and it
  ends released, failed or timed out, each step in the board's activity.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments, Lanes, Releases, Repo, Runners}
  alias Slipdock.Boards.{Activity, Card}
  alias Slipdock.Releases.Request
  alias Slipdock.Runners.{Job, Runner}

  setup do
    owner = user_fixture("release-req-#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Release requests", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{"delivery_metrics" => true, "release_mode" => "batched"})

    [_backlog, todo, doing | _] = board.columns
    %{owner: owner, board: board, todo: todo, doing: doing}
  end

  # A runner on the tree that has said which job kinds it takes.
  defp runner!(board, name, kinds, pool \\ "dev") do
    {:ok, runner, _token} = Runners.create_runner(board, %{"name" => name, "pool" => pool})
    Runners.report_kinds(runner, Enum.join(kinds, ","))
  end

  # A card accepted and merged, as the merge job leaves it.
  defp merged!(column, title, fields \\ []) do
    card = card_fixture(column, %{"title" => title})

    Repo.update_all(
      from(c in Card, where: c.id == ^card.id),
      set:
        Keyword.merge(
          [
            completed: true,
            completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            verify_state: "accepted",
            merge_sha: "abc1234def5678"
          ],
          fields
        )
    )

    Repo.get!(Card, card.id)
  end

  defp activity(board) do
    Repo.all(
      from(a in Activity,
        where: a.board_id == ^board.id and a.kind == "release",
        order_by: a.id,
        select: a.message
      )
    )
  end

  defp deploy!(board, card, status \\ "succeeded", extra \\ %{}) do
    now = DateTime.utc_now()

    {:ok, d} =
      Deployments.start(
        board,
        Map.merge(
          %{
            environment: "production",
            sha: "feed00#{System.unique_integer([:positive])}",
            status: status,
            started_at: now,
            finished_at: now,
            commits: [%{"sha" => "abc1234def5678", "subject" => "feat ##{card.id}"}]
          },
          extra
        )
      )

    d
  end

  defp hours_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 3600) |> DateTime.truncate(:second)

  describe "the release command" do
    test "is one line of at most 500 characters; blank is the default", %{board: board} do
      {:error, cs} = Boards.update_board(board, %{"release_command" => "make a\nrm -rf b"})
      assert "must be one line" in errors_on(cs).release_command

      {:error, cs} =
        Boards.update_board(board, %{"release_command" => String.duplicate("x", 501)})

      assert [_too_long] = errors_on(cs).release_command

      {:ok, board} = Boards.update_board(board, %{"release_command" => "make release"})
      assert Releases.settings(board).command == "make release"
      assert Releases.settings(board.id).command == "make release"

      {:ok, board} = Boards.update_board(board, %{"release_command" => "  "})
      assert board.release_command == nil
      assert Releases.command(board) == "gh workflow run release.yml --ref {default_branch}"
    end
  end

  describe "request/3" do
    test "is refused on a board that releases on merge", %{board: board} do
      {:ok, board} = Boards.update_board(board, %{"release_mode" => "on_merge"})
      runner!(board, "box", ~w(merge release))

      assert Releases.request(board, "manual", "Dana") == {:error, :not_batched}
      assert Repo.aggregate(Request, :count) == 0
      assert Releases.refusal(:not_batched) =~ "releases on merge"
    end

    test "with no runner that merges or releases, nothing starts and the board says so",
         %{board: board} do
      runner!(board, "builder", ~w(claude))

      assert {:error, message} = Releases.request(board, "manual", "Dana")
      assert message == "no runner on this board takes release or merge jobs"
      assert Repo.aggregate(Request, :count) == 0
      assert activity(board) == ["Release not started: #{message}"]
    end

    test "with the tree's job queue full, nothing starts and the board says so", %{board: board} do
      runner!(board, "box", ~w(merge release))

      for _ <- 1..200 do
        Repo.insert!(%Job{
          board_id: board.id,
          root_board_id: board.id,
          pool: "dev",
          kind: "probe",
          prompt: "x",
          status: "queued"
        })
      end

      assert {:error, message} = Releases.request(board, "age_cap", "#1 has waited 5h, cap 4h")
      assert message =~ "the queue is full"
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(from(j in Job, where: j.kind == "release"), :count) == 0
      assert [said] = activity(board)
      assert said =~ "Release not started: the queue is full"
    end

    test "queueing the release job wakes the pool's waiting runners", %{board: board} do
      runner!(board, "box", ~w(merge release))
      Phoenix.PubSub.subscribe(Slipdock.PubSub, "runner_queue:#{board.id}:dev")

      assert {:ok, :started, _} = Releases.request(board, "manual", "Dana")
      assert_receive :job_queued
    end

    test "starts a release: the cards awaiting, a card-less release job, the activity",
         %{board: board, todo: todo} do
      runner!(board, "box", ~w(merge release))
      one = merged!(todo, "One", completed_at: hours_ago(2))
      two = merged!(todo, "Two", completed_at: hours_ago(1))
      _unmerged = card_fixture(todo, %{"title" => "Open"})

      assert {:ok, :started, request} = Releases.request(board, "manual", "Dana")
      assert request.status == "running"
      assert request.card_ids == [one.id, two.id]
      assert [%{"trigger" => "manual", "by" => "Dana", "at" => _}] = request.triggers
      assert %DateTime{} = request.started_at

      job = Repo.get!(Job, request.job_id)
      assert {job.kind, job.card_id, job.pool, job.status} == {"release", nil, "dev", "queued"}
      assert {job.board_id, job.root_board_id} == {board.id, board.id}
      assert job.prompt == "gh workflow run release.yml --ref {default_branch}"
      assert Runners.claimed_prompt(job) == job.prompt

      assert [line] = activity(board)
      assert line =~ "Release started (job ##{job.id}, pool dev): Release now by Dana."
      assert line =~ "Covers ##{one.id}, ##{two.id}."
    end

    test "the job runs the board's own release command when it has one", %{board: board} do
      runner!(board, "box", ~w(merge))
      {:ok, board} = Boards.update_board(board, %{"release_command" => " make release "})

      assert {:ok, :started, request} = Releases.request(board, "manual", "Dana")
      assert Repo.get!(Job, request.job_id).prompt == "make release"
      assert Releases.command(board) == "make release"
      assert activity(board) |> hd() =~ "No merged card is awaiting release."
    end

    test "a sub-board's request is its root's", %{board: board, todo: todo} do
      runner!(board, "box", ~w(merge release))
      epic = card_fixture(todo, %{"title" => "Epic"})
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, template)
      sub = Repo.preload(sub, :columns)
      inner = merged!(hd(sub.columns), "Inner")

      # The command is the root's too: a sub-board refuses one of its own.
      {:error, cs} = Boards.update_board(sub, %{"release_command" => "make release"})
      assert "is set on the tree's root board (#{board.code})" in errors_on(cs).release_command

      assert {:ok, :started, request} = Releases.request(sub, "manual", "Dana")
      assert request.board_id == board.id
      assert request.card_ids == [inner.id]
      assert Releases.command(sub) == Releases.default_command()
    end

    test "one at a time: the second queues a single follow-up and the third joins it",
         %{board: board} do
      runner!(board, "box", ~w(merge release))

      assert {:ok, :started, running} = Releases.request(board, "manual", "Dana")
      assert {:ok, :queued, queued} = Releases.request(board, "critical", "#7 Fix")
      assert {:ok, :joined, joined} = Releases.request(board, "age_cap", "#3 has waited 9h")

      assert queued.status == "queued" and queued.job_id == nil
      assert joined.id == queued.id
      assert Enum.map(joined.triggers, & &1["trigger"]) == ["critical", "age_cap"]

      assert Repo.aggregate(Request, :count) == 2
      assert Repo.aggregate(from(j in Job, where: j.kind == "release"), :count) == 1

      status = Releases.status(board)
      assert {status.running.id, status.queued.id, status.last} == {running.id, queued.id, nil}
      assert Releases.line(status) == "A release is running (0 cards) · another is queued"

      assert [_started, queued_line, joined_line] = activity(board)
      assert queued_line == "Release queued behind the one running: critical card #7 Fix merged"
      assert joined_line =~ "Release already queued; joined by the age cap (#3 has waited 9h)"
    end

    test "an idle releaser's pool is taken before a busy or unseen one's", %{board: board} do
      runner!(board, "unseen", ~w(merge release), "cold-pool")
      idle = runner!(board, "idle", ~w(merge release), "warm-pool")

      Repo.update_all(from(r in Runner, where: r.id == ^idle.id),
        set: [last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      assert {:ok, :started, request} = Releases.request(board, "manual", "Dana")
      assert Repo.get!(Job, request.job_id).pool == "warm-pool"
    end

    test "an idle releaser is taken before a busier one seen more lately", %{
      board: board,
      todo: todo
    } do
      busy = runner!(board, "busy", ~w(claude merge release), "busy-pool")
      idle = runner!(board, "idle", ~w(merge release), "idle-pool")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(from(r in Runner, where: r.id == ^idle.id),
        set: [last_seen_at: DateTime.add(now, -30)]
      )

      {:ok, _} =
        Runners.queue(card_fixture(todo), %{pool: "busy-pool", kind: "claude", prompt: "go"})

      assert %Job{} = Runners.claim(busy)
      Repo.update_all(from(r in Runner, where: r.id == ^busy.id), set: [last_seen_at: now])
      refute Runners.idle?(Repo.get!(Runner, busy.id))
      assert Runners.idle?(Repo.get!(Runner, idle.id))

      assert {:ok, :started, request} = Releases.request(board, "manual", "Dana")
      assert Repo.get!(Job, request.job_id).pool == "idle-pool"
    end

    test "a release of more than twenty cards names twenty and counts the rest", %{
      board: board,
      todo: todo
    } do
      runner!(board, "box", ~w(merge release))
      cards = for n <- 1..22, do: merged!(todo, "Card #{n}")

      assert {:ok, :started, request} = Releases.request(board, "manual", nil)
      assert length(request.card_ids) == 22

      [line] = activity(board)
      assert line =~ "Release now by somebody."
      assert line =~ "##{Enum.at(cards, 19).id} and 2 more."
      refute line =~ "##{Enum.at(cards, 20).id}"
    end

    test "what the doors say of each outcome", %{board: board, todo: todo} do
      assert Releases.said(:started) =~ "Release started"
      assert Releases.said(:queued) =~ "Release queued"
      assert Releases.said(:joined) =~ "already queued"
      assert Releases.refusal("no runner") == "no runner"

      # Nothing to say, then the cards awaiting, then the release running.
      assert Releases.line(Releases.status(board)) == nil
      merged!(todo, "One")
      merged!(todo, "Two")
      assert Releases.line(Releases.status(board)) == "2 merged, awaiting release"

      runner!(board, "box", ~w(merge release))
      {:ok, :started, _} = Releases.request(board, "manual", "Dana")
      assert Releases.line(Releases.status(board)) == "A release is running (2 cards)"
    end

    test "prefers a pool whose runner takes release over one that only merges", %{board: board} do
      runner!(board, "merger", ~w(merge), "merge-pool")
      runner!(board, "releaser", ~w(merge release), "release-pool")

      assert {:ok, :started, request} = Releases.request(board, "manual", "Dana")
      assert Repo.get!(Job, request.job_id).pool == "release-pool"
    end
  end

  describe "the release job at the claim" do
    test "goes only to a runner that says it takes release", %{board: board} do
      merger = runner!(board, "merger", ~w(claude merge))
      {:ok, :started, request} = Releases.request(board, "manual", "Dana")

      assert Runners.claim(merger) == nil

      releaser = runner!(board, "releaser", ~w(merge release))
      assert %Job{id: id, kind: "release"} = Runners.claim(releaser)
      assert id == request.job_id
      assert Runners.takes_release?(releaser)
      refute Runners.takes_release?(merger)
      refute Runners.takes_release?(%Runner{kinds: nil})
    end

    test "is never held by a full WIP limit, where a work job waits", %{
      board: board,
      todo: todo,
      doing: doing
    } do
      doing |> Ecto.Changeset.change(wip_limit: 1) |> Repo.update!()

      Repo.update_all(from(b in Slipdock.Boards.Board, where: b.id == ^board.id),
        set: [automation_wip: true]
      )

      card_fixture(doing, %{"title" => "In progress"})
      releaser = runner!(board, "releaser", ~w(claude merge release))

      {:ok, work} =
        Runners.queue(card_fixture(todo), %{pool: "dev", kind: "claude", prompt: "go"})

      assert Runners.held_reason(Repo.reload!(work), claimant: true) =~ "WIP full"

      {:ok, :started, request} = Releases.request(board, "manual", "Dana")
      assert %Job{id: id} = Runners.claim(releaser)
      assert id == request.job_id
    end

    test "is never held by a lane", %{board: board, todo: todo, doing: doing} do
      {:ok, board} = Boards.update_board(board, %{"lanes" => true})
      releaser = runner!(board, "releaser", ~w(claude merge release))

      running = card_fixture(doing, %{"title" => "Running"})
      {:ok, running} = Boards.Cards.update_card(running, %{"paths" => "lib/a/**"})
      working_job_fixture(running)
      held = card_fixture(todo, %{"title" => "Held"})
      {:ok, held} = Boards.Cards.update_card(held, %{"paths" => "lib/a/b.ex"})
      {:ok, _held_job} = Runners.queue(held, %{pool: "dev", kind: "claude", prompt: "go"})
      assert Map.keys(Lanes.held_cards(board.id)) == [held.id]

      {:ok, :started, request} = Releases.request(board, "manual", "Dana")
      assert %Job{id: id} = Runners.claim(releaser)
      assert id == request.job_id
    end
  end

  describe "a release of exactly twenty cards" do
    test "names them all and counts no more", %{board: board, todo: todo} do
      runner!(board, "box", ~w(merge release))
      cards = for n <- 1..20, do: merged!(todo, "Card #{n}")

      assert {:ok, :started, _request} = Releases.request(board, "manual", nil)

      [line] = activity(board)
      assert String.ends_with?(line, "##{List.last(cards).id}.")
      refute line =~ "more"
    end
  end

  describe "missing_kinds/1 (#2836)" do
    test "names release for a runner that merges but doesn't release, on a batched tree only",
         %{board: board} do
      old = runner!(board, "old", ~w(claude merge))
      new = runner!(board, "new", ~w(claude merge release))
      builder = runner!(board, "builder", ~w(claude))

      assert Runners.missing_kinds(old) == ["release"]
      assert Runners.missing_kinds(new) == []
      # A runner that doesn't merge isn't asked to release either.
      assert Runners.missing_kinds(builder) == []

      {:ok, _} = Boards.update_board(board, %{"release_mode" => "on_merge"})
      assert Runners.missing_kinds(old) == []
    end

    test "a Claude session's runner is asked for neither", %{board: board, owner: owner} do
      {:ok, board} =
        Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

      {_token, api_token} = Slipdock.Accounts.create_api_token(owner, "desktop")
      {:ok, session} = Runners.session_runner(board, "dev", api_token, owner)

      assert Runners.missing_kinds(session) == []
      assert Runners.missing_kinds(Runners.report_kinds(session, "claude,merge")) == []
    end

    test "merge and release are both named when the tree ships by pull request",
         %{board: board} do
      {:ok, board} =
        Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

      assert Runners.missing_kinds(runner!(board, "builder", ~w(claude))) == ["merge"]
      assert Runners.missing_kinds(runner!(board, "old", ~w(claude merge))) == ["release"]
    end
  end

  describe "how a release ends" do
    setup %{board: board} do
      %{runner: runner!(board, "box", ~w(merge release))}
    end

    defp fire!(runner, request, attrs) do
      %Job{id: id} = Runners.claim(runner)
      assert id == request.job_id
      {:ok, job} = Runners.finish(runner, id, attrs)
      job
    end

    test "a done job keeps the run's link and waits for the deploy", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")

      fire!(ctx.runner, request, %{
        exit: "0",
        status: "done",
        output: "ok\nhttps://github.com/example/app/actions/runs/42\n"
      })

      request = Repo.get!(Request, request.id)
      assert request.status == "running"
      assert request.run_url == "https://github.com/example/app/actions/runs/42"
      assert List.last(activity(ctx.board)) =~ "Release fired by job ##{request.job_id}: https://"
    end

    test "the run the daemon names wins over any other link in the log (#2836)", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")

      fire!(ctx.runner, request, %{
        exit: "0",
        status: "done",
        output:
          "From https://github.com/example/app\n * branch main\n" <>
            "release: run https://github.com/example/app/actions/runs/42\n"
      })

      assert Repo.get!(Request, request.id).run_url ==
               "https://github.com/example/app/actions/runs/42"
    end

    test "a failed job's request says what the daemon said (#2836)", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")

      fire!(ctx.runner, request, %{
        exit: "2",
        status: "failed",
        output:
          "release: could not fetch origin\nrelease: gh is not signed in (run gh auth login)\n"
      })

      assert %{status: "failed", note: note} = Repo.get!(Request, request.id)
      assert note == "job ##{request.job_id} failed: gh is not signed in (run gh auth login)"
    end

    test "a failed job whose output has no release: line says the command didn't run", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")

      fire!(ctx.runner, request, %{
        exit: "1",
        status: "failed",
        output: "make: *** [release] Error 1\nreleases are fun\n"
      })

      assert %{status: "failed", note: note} = Repo.get!(Request, request.id)
      assert note == "job ##{request.job_id} failed: the release command didn't run"
    end

    test "on a tree that records no deploys, a done job is the release", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"delivery_metrics" => false})
      {:ok, :started, request} = Releases.request(board, "manual", "Dana")

      fire!(ctx.runner, request, %{exit: "0", status: "done"})

      request = Repo.get!(Request, request.id)
      assert request.status == "released"
      assert request.run_url == nil
      assert request.note =~ "records no deploys"
      assert %DateTime{} = request.finished_at
    end

    test "with no deploys recorded, the cards the request covered read released", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"delivery_metrics" => false})
      card = merged!(ctx.todo, "Ships")
      later = merged!(ctx.todo, "Later")
      Repo.update_all(from(c in Card, where: c.id == ^later.id), set: [completed: false])
      assert %{state: "awaiting"} = Releases.state(card)

      {:ok, :started, request} = Releases.request(board, "manual", "Dana")
      assert request.card_ids == [card.id]
      # Running, not released yet.
      assert %{state: "awaiting"} = Releases.state(card)

      fire!(ctx.runner, request, %{exit: "0", status: "done"})
      request = Repo.get!(Request, request.id)

      assert %{state: "released", environment: nil, deployment_id: nil, at: at} =
               state = Releases.state(card)

      assert at == request.finished_at
      assert Releases.text(state) =~ ~r/^Released · \d+ \w+ \d\d:\d\d$/

      # A card the request didn't cover is still awaiting.
      other = merged!(ctx.todo, "Other", completed_at: DateTime.add(DateTime.utc_now(), 60))
      assert %{state: "awaiting"} = Releases.state(other)
    end

    test "a run link longer than the column keeps none, and the activity says fired", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      long = "https://ci.example.com/" <> String.duplicate("x", 500)

      fire!(ctx.runner, request, %{exit: "0", status: "done", output: long})

      assert Repo.get!(Request, request.id).run_url == nil
      assert List.last(activity(ctx.board)) == "Release fired by job ##{request.job_id}."
    end

    test "a run link of exactly the column's length is kept", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      link = "https://ci.example.com/" <> String.duplicate("x", 477)
      assert byte_size(link) == 500

      fire!(ctx.runner, request, %{exit: "0", status: "done", output: link})
      assert Repo.get!(Request, request.id).run_url == link
    end

    test "its queued job cancelled fails the release, and the follow-up starts", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      {:ok, :queued, queued} = Releases.request(ctx.board, "manual", "Eli")

      {:ok, _} = Runners.cancel_job(Repo.get!(Job, request.job_id))

      assert %Request{status: "failed", note: note} = Repo.get!(Request, request.id)
      assert note == "job ##{request.job_id} cancelled: the release command didn't run"
      assert Repo.get!(Request, queued.id).status == "running"
    end

    test "its lease running out for the last time fails the release", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      %Job{id: id} = Runners.claim(ctx.runner)

      Repo.update_all(from(j in Job, where: j.id == ^id),
        set: [attempts: Runners.max_attempts(), lease_expires_at: hours_ago(1)]
      )

      assert Runners.sweep() == 1
      assert Repo.get!(Job, id).status == "failed"

      assert %Request{status: "failed", note: note} = Repo.get!(Request, request.id)
      assert note == "job ##{id} failed: the release command didn't run"
    end

    test "asked to stop, then its lease out: the job is cancelled and the release fails", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      %Job{id: id} = Runners.claim(ctx.runner)

      {:ok, _} = Runners.cancel_job(Repo.get!(Job, id))
      # Asked to stop, not yet stopped: the release is still running.
      assert Repo.get!(Request, request.id).status == "running"

      Repo.update_all(from(j in Job, where: j.id == ^id), set: [lease_expires_at: hours_ago(1)])
      assert Runners.sweep() == 1
      assert Repo.get!(Job, id).status == "cancelled"
      assert Repo.get!(Request, request.id).status == "failed"
    end

    test "a lease that runs out with tries left requeues the job; the release runs on", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      %Job{id: id} = Runners.claim(ctx.runner)

      Repo.update_all(from(j in Job, where: j.id == ^id), set: [lease_expires_at: hours_ago(1)])
      assert Runners.sweep() == 1
      assert Repo.get!(Job, id).status == "queued"
      assert Repo.get!(Request, request.id).status == "running"
    end

    test "a started deploy that then fails through record_failure fails the release", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      fire!(ctx.runner, request, %{exit: "0", status: "done"})

      {:ok, _started} =
        Deployments.start(ctx.board, %{
          environment: "production",
          sha: "feed0042",
          status: "started",
          started_at: DateTime.utc_now()
        })

      assert Repo.get!(Request, request.id).status == "running"

      {:ok, failed} =
        Deployments.record_failure(ctx.board, %{
          environment: "production",
          sha: "feed0042",
          stage: "deploy"
        })

      # The deploy job's own attempt, finished as failed: one row.
      assert Repo.aggregate(Deployments.Deployment, :count) == 1
      assert failed.status == "failed"

      assert %Request{status: "failed", note: "the release failed at deploy"} =
               Repo.get!(Request, request.id)
    end

    test "a job that hasn't ended changes nothing: queued, claimed or running", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      {:ok, :queued, queued} = Releases.request(ctx.board, "manual", "Eli")
      said = activity(ctx.board)

      assert Releases.job_finished(Repo.get!(Job, request.job_id)) == :ok

      %Job{id: id} = Runners.claim(ctx.runner)

      for status <- ["claimed", "running"] do
        Repo.update_all(from(j in Job, where: j.id == ^id), set: [status: status])
        assert Releases.job_finished(Repo.get!(Job, id)) == :ok
      end

      # Still the one release: it runs on, and its follow-up waits.
      assert Repo.get!(Request, request.id).status == "running"
      assert Repo.get!(Request, queued.id).status == "queued"
      assert activity(ctx.board) == said
    end

    test "a job that ends after its request did changes nothing", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      {:ok, _} = Releases.finish(request, "timed_out", "late")

      fire!(ctx.runner, request, %{exit: "1", status: "failed"})
      assert Repo.get!(Request, request.id).status == "timed_out"
    end

    test "a job done after its request ended keeps no link and says nothing", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      {:ok, _} = Releases.finish(request, "failed", "gave up")
      said = activity(ctx.board)

      fire!(ctx.runner, request, %{
        exit: "0",
        status: "done",
        output: "release: run https://github.com/example/app/actions/runs/7"
      })

      assert %Request{status: "failed", run_url: nil} = Repo.get!(Request, request.id)
      assert activity(ctx.board) == said
    end

    test "a rolled-back deploy ends nothing", ctx do
      card = merged!(ctx.todo, "Ships")
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")

      deploy!(ctx.board, card, "succeeded", %{rollback: true})
      assert Repo.get!(Request, request.id).status == "running"
    end

    test "a follow-up no runner can take is dropped, and the board says so", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      {:ok, :queued, queued} = Releases.request(ctx.board, "manual", "Eli")
      Repo.update_all(from(r in Runner, where: r.board_id == ^ctx.board.id), set: [kinds: []])

      {:ok, _} = Releases.finish(request, "released")

      assert Repo.get(Request, queued.id) == nil
      assert Releases.status(ctx.board).queued == nil

      assert List.last(activity(ctx.board)) ==
               "Release not started: no runner on this board takes release or merge jobs"
    end

    test "a failed job fails the release, and the follow-up starts", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      {:ok, :queued, queued} = Releases.request(ctx.board, "manual", "Eli")

      fire!(ctx.runner, request, %{exit: "1", status: "failed"})

      assert %{status: "failed", note: note} = Repo.get!(Request, request.id)
      assert note =~ "the release command didn't run"

      queued = Repo.get!(Request, queued.id)
      assert queued.status == "running"
      assert queued.job_id != request.job_id
      assert Repo.get!(Job, queued.job_id).status == "queued"
      assert Releases.status(ctx.board).last.id == request.id
    end

    test "a succeeded deploy releases it; its cards stop awaiting", ctx do
      card = merged!(ctx.todo, "Ships")
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      assert Enum.map(Releases.awaiting(ctx.board), & &1.id) == [card.id]

      deploy!(ctx.board, card)

      assert %{status: "released", note: "deployed to production"} =
               Repo.get!(Request, request.id)

      assert Releases.awaiting(ctx.board) == []
      assert Releases.line(Releases.status(ctx.board)) == nil
      assert List.last(activity(ctx.board)) == "Release released: deployed to production."
    end

    test "a deploy finished later ends it too, and a failed one fails it at its stage", ctx do
      card = merged!(ctx.todo, "Ships")
      {:ok, :started, first} = Releases.request(ctx.board, "manual", "Dana")
      started = deploy!(ctx.board, card, "started", %{finished_at: nil})
      assert Repo.get!(Request, first.id).status == "running"

      {:ok, _} = Deployments.finish(ctx.board, started.id, "succeeded")
      assert Repo.get!(Request, first.id).status == "released"

      {:ok, :started, second} = Releases.request(ctx.board, "manual", "Dana")

      {:ok, _} =
        Deployments.record_failure(ctx.board, %{
          environment: "production",
          sha: "bad0001",
          stage: "test",
          run_url: "https://ci.example.com/runs/9"
        })

      assert %{status: "failed", note: "the release failed at test"} =
               Repo.get!(Request, second.id)
    end

    test "a backfilled deploy and one with nothing running end nothing", ctx do
      card = merged!(ctx.todo, "Ships")
      # Nothing running: recording a deploy is not an error.
      deploy!(ctx.board, card)

      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      deploy!(ctx.board, card, "succeeded", %{source: "backfill"})
      assert Repo.get!(Request, request.id).status == "running"
    end

    test "finish/3 ends a request once", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")

      assert {:ok, %Request{status: "released"}} = Releases.finish(request, "released")
      assert Releases.finish(request, "failed", "late") == {:error, :not_running}
      assert Repo.get!(Request, request.id).status == "released"
    end

    test "finish/3 keeps the first 500 characters of a long note", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      note = String.duplicate("n", 499) <> "ab"

      assert {:ok, %Request{note: kept}} = Releases.finish(request, "failed", note)
      assert kept == String.duplicate("n", 499) <> "a"
    end
  end

  describe "awaiting/1" do
    test "merged cards no succeeded deploy names, oldest first; never archived or unmerged",
         %{board: board, todo: todo} do
      newer = merged!(todo, "Newer", completed_at: hours_ago(1))
      older = merged!(todo, "Older", completed_at: hours_ago(5))
      by_push = merged!(todo, "Pushed", merge_sha: nil, verify_commit: "c0ffee1")
      _no_commit = merged!(todo, "No code", merge_sha: nil)
      _pending = merged!(todo, "Pending", verify_state: "merging")
      archived = merged!(todo, "Archived")

      Repo.update_all(from(c in Card, where: c.id == ^archived.id),
        set: [archived_at: hours_ago(0)]
      )

      assert Enum.map(Releases.awaiting(board), & &1.id) == [older.id, newer.id, by_push.id]
    end

    test "a card a succeeded deploy names stops awaiting, whenever the deploy started", %{
      board: board,
      todo: todo
    } do
      named = merged!(todo, "Named")
      other = merged!(todo, "Other")

      # A deploy that started before either merged: only its naming the
      # card takes it off the list.
      deploy!(board, named, "succeeded", %{started_at: hours_ago(2), finished_at: hours_ago(2)})

      assert Enum.map(Releases.awaiting(board), & &1.id) == [other.id]
    end

    test "nothing on a board that releases on merge", %{board: board, todo: todo} do
      merged!(todo, "One")
      {:ok, board} = Boards.update_board(board, %{"release_mode" => "on_merge"})
      assert Releases.awaiting(board) == []
    end

    test "a card merged before the last release that no deploy named doesn't wait for ever",
         %{board: board, todo: todo} do
      runner!(board, "box", ~w(merge release))
      unnamed = merged!(todo, "Unnamed", completed_at: hours_ago(3))
      shipped = merged!(todo, "Shipped", completed_at: hours_ago(2))
      assert length(Releases.awaiting(board)) == 2

      deploy!(board, shipped)
      later = merged!(todo, "Later", completed_at: DateTime.add(DateTime.utc_now(), 60))

      assert Enum.map(Releases.awaiting(board), & &1.id) == [later.id]
      refute Enum.member?(Enum.map(Releases.awaiting(board), & &1.id), unnamed.id)
    end
  end

  describe "awaiting/1 and what didn't release" do
    test "a failed deploy naming a card leaves it awaiting, and is no last release", %{
      board: board,
      todo: todo
    } do
      card = merged!(todo, "Red", completed_at: hours_ago(3))
      deploy!(board, card, "failed")

      assert Enum.map(Releases.awaiting(board), & &1.id) == [card.id]
    end

    test "a card finished at the very start of the last release is not awaiting", %{
      board: board,
      todo: todo
    } do
      at = hours_ago(2)
      merged!(todo, "On the dot", completed_at: at)
      later = merged!(todo, "A second later", completed_at: DateTime.add(at, 1))

      Repo.insert!(%Request{
        board_id: board.id,
        status: "released",
        started_at: %{at | microsecond: {0, 6}}
      })

      assert Enum.map(Releases.awaiting(board), & &1.id) == [later.id]
    end

    test "a failed request is no last release; a released one is", %{board: board, todo: todo} do
      card = merged!(todo, "Waiting", completed_at: hours_ago(3))

      failed =
        Repo.insert!(%Request{
          board_id: board.id,
          status: "failed",
          started_at: DateTime.utc_now()
        })

      assert Enum.map(Releases.awaiting(board), & &1.id) == [card.id]

      failed |> Ecto.Changeset.change(status: "released") |> Repo.update!()
      assert Releases.awaiting(board) == []
    end
  end

  describe "card_merged/1" do
    setup %{board: board} do
      %{runner: runner!(board, "box", ~w(merge release))}
    end

    test "a critical card's merge asks for a release, naming it", %{board: board, todo: todo} do
      card = merged!(todo, "Hotfix", priority: "critical")

      assert {:ok, :started, request} = Releases.card_merged(card)
      assert [%{"trigger" => "critical", "by" => by}] = request.triggers
      assert by == "##{card.id} Hotfix"
      assert request.card_ids == [card.id]
      assert hd(activity(board)) =~ "critical card ##{card.id} Hotfix merged"
    end

    test "any other priority, a card with no commit and an on_merge board ask for nothing",
         %{board: board, todo: todo} do
      assert Releases.card_merged(merged!(todo, "Plain", priority: "high")) == :ok

      assert Releases.card_merged(merged!(todo, "None", priority: "critical", merge_sha: nil)) ==
               :ok

      {:ok, _} = Boards.update_board(board, %{"release_mode" => "on_merge"})
      assert Releases.card_merged(merged!(todo, "Hot", priority: "critical")) == :ok
      assert Repo.aggregate(Request, :count) == 0
    end
  end

  describe "a critical card through the real merge" do
    defp submit_and_accept(card, owner, evidence) do
      builder = %{
        Slipdock.Actor.unknown()
        | kind: "agent",
          via: "api",
          user_id: owner.id,
          agent: "builder"
      }

      checker = %{builder | agent: "checker"}

      {:ok, card} =
        Boards.Cards.update_card(
          Repo.get!(Card, card.id),
          Map.merge(%{"completed" => true, "evidence_commit" => "abc1234"}, evidence),
          actor: builder
        )

      assert card.verify_state == "pending"
      Slipdock.Verified.decide(Repo.get!(Card, card.id), "accept", %{}, checker, owner)
    end

    test "by pull request: the merge job's finish asks for the release", ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

      runner = runner!(board, "box", ~w(merge release))
      card = card_fixture(ctx.doing, %{"title" => "Hotfix", "priority" => "critical"})
      plain = card_fixture(ctx.doing, %{"title" => "Plain"})
      pr = %{"evidence_pr" => "https://github.com/example/app/pull/7"}

      {:ok, _} = submit_and_accept(plain, ctx.owner, pr)
      %Job{kind: "merge"} = job = Runners.claim(runner)
      {:ok, _} = Runners.finish(runner, job.id, %{exit: "0", status: "done", merged: "feed1234"})
      # A merge of any other priority asks for nothing.
      assert Repo.aggregate(Request, :count) == 0

      {:ok, _} = submit_and_accept(card, ctx.owner, pr)
      # Accepted, not yet merged: nothing is asked for.
      assert Repo.aggregate(Request, :count) == 0
      %Job{kind: "merge"} = job = Runners.claim(runner)
      {:ok, _} = Runners.finish(runner, job.id, %{exit: "0", status: "done", merged: "c0ffee12"})

      assert [%Request{status: "running", triggers: [%{"trigger" => "critical"}]} = request] =
               Repo.all(Request)

      # It takes whatever else has merged since the last release.
      assert Enum.sort(request.card_ids) == Enum.sort([plain.id, card.id])
      assert %Job{kind: "release", id: id} = Runners.claim(runner)
      assert id == request.job_id
    end

    test "by push: accepting the card is its merge", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
      runner!(board, "box", ~w(merge release))
      card = card_fixture(ctx.doing, %{"title" => "Hotfix", "priority" => "critical"})

      {:ok, _} = submit_and_accept(card, ctx.owner, %{})

      assert [%Request{status: "running", card_ids: [id]}] = Repo.all(Request)
      assert id == card.id
    end
  end

  describe "tick/1" do
    setup %{board: board} do
      {:ok, board} = Boards.update_board(board, %{"release_age_cap_hours" => 4})
      %{board: board, runner: runner!(board, "box", ~w(merge release))}
    end

    test "the age cap asks once the oldest merge has waited that long", ctx do
      merged!(ctx.todo, "Young", completed_at: hours_ago(3))
      assert Releases.tick() == 0
      assert Repo.aggregate(Request, :count) == 0

      old = merged!(ctx.todo, "Old", completed_at: hours_ago(5))
      assert Releases.tick() == 1

      assert [%Request{status: "running", triggers: [%{"trigger" => "age_cap", "by" => by}]}] =
               Repo.all(Request)

      assert by == "##{old.id} has waited 5h, cap 4h"
      # A release is open: the cap asks for no second one.
      assert Releases.tick() == 0
      assert Repo.aggregate(Request, :count) == 1
    end

    test "the last request to end is the later one: status/1 gives it and the cap reads it",
         ctx do
      long_ago = DateTime.add(DateTime.utc_now(), -10 * 3600)

      Repo.insert!(%Request{board_id: ctx.board.id, status: "failed", started_at: long_ago})

      released =
        Repo.insert!(%Request{board_id: ctx.board.id, status: "released", started_at: long_ago})

      assert Releases.status(ctx.board).last.id == released.id

      # The last one released, so the cap is not held off by the failure before it.
      merged!(ctx.todo, "Old", completed_at: hours_ago(5))
      assert Releases.tick() == 1
    end

    test "a release times out at exactly the timeout", ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      started = Repo.get!(Request, request.id).started_at
      on_the_dot = DateTime.add(started, Releases.timeout_hours() * 3600)

      assert Releases.tick(DateTime.add(on_the_dot, -1)) == 0
      assert Releases.tick(on_the_dot) == 1
      assert Repo.get!(Request, request.id).status == "timed_out"
    end

    test "the age cap asks at exactly the cap", ctx do
      old = merged!(ctx.todo, "On the hour", completed_at: hours_ago(4))
      assert Releases.tick() == 1
      assert [%Request{triggers: [%{"by" => by}]}] = Repo.all(Request)
      assert by == "##{old.id} has waited 4h, cap 4h"
    end

    test "an archived board, and a card with no merge time, never ask", ctx do
      merged!(ctx.todo, "Timeless", completed_at: nil)
      assert Releases.tick() == 0

      merged!(ctx.todo, "Old", completed_at: hours_ago(9))

      Repo.update_all(from(b in Slipdock.Boards.Board, where: b.id == ^ctx.board.id),
        set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      assert Releases.tick() == 0
      assert Repo.aggregate(Request, :count) == 0
    end

    test "a release that fired and then went quiet times out, its finished job left alone",
         ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      %Job{id: id} = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, id, %{exit: "0", status: "done"})

      at = DateTime.add(DateTime.utc_now(), Releases.timeout_hours() * 3600 + 60)
      assert Releases.tick(at) == 1
      assert Repo.get!(Request, request.id).status == "timed_out"
      assert Repo.get!(Job, id).status == "done"
      # Timed out: the cap asks for nothing more.
      merged!(ctx.todo, "Old", completed_at: hours_ago(9))
      assert Releases.tick() == 0
    end

    test "no cap, or an on_merge board, never asks", ctx do
      merged!(ctx.todo, "Old", completed_at: hours_ago(50))
      {:ok, board} = Boards.update_board(ctx.board, %{"release_age_cap_hours" => nil})
      assert Releases.tick() == 0

      {:ok, _} =
        Boards.update_board(board, %{"release_age_cap_hours" => 4, "release_mode" => "on_merge"})

      assert Releases.tick() == 0
    end

    test "after a failed release the cap holds off; a person's release is not held", ctx do
      merged!(ctx.todo, "Old", completed_at: hours_ago(9))
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      {:ok, _} = Releases.finish(request, "failed", "red")

      assert Releases.tick() == 0
      assert {:ok, :started, _} = Releases.request(ctx.board, "manual", "Dana")
    end

    test "a release nothing was heard of for the timeout ends timed out, its job cancelled",
         ctx do
      {:ok, :started, request} = Releases.request(ctx.board, "manual", "Dana")
      {:ok, :queued, queued} = Releases.request(ctx.board, "manual", "Eli")
      at = DateTime.utc_now()

      assert Releases.tick(DateTime.add(at, Releases.timeout_hours() * 3600 - 120)) == 0
      assert Repo.get!(Request, request.id).status == "running"

      assert Releases.tick(DateTime.add(at, Releases.timeout_hours() * 3600 + 60)) == 1

      assert %{status: "timed_out", note: "nothing heard for 3 hours"} =
               Repo.get!(Request, request.id)

      assert Repo.get!(Job, request.job_id).status == "cancelled"
      assert Repo.get!(Request, queued.id).status == "running"
    end
  end
end
