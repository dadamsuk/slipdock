defmodule Slipdock.RunnersTest do
  # The job queue on its own: queueing, claiming, leases, heartbeats,
  # finishing, cancelling and the sweep that takes back abandoned work.
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Runners.{Job, Runner}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Runners"}, owner: owner)
    [todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Fix the login page"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "dev-box", "pool" => "dev"})
    %{owner: owner, board: board, todo: todo, card: card, runner: runner, token: token}
  end

  defp queue(card, attrs \\ %{}),
    do: Runners.queue(card, Map.merge(%{pool: "dev", kind: "claude", prompt: "do it"}, attrs))

  defp fresh(job), do: Repo.get!(Job, job.id)

  defp expire_lease(job) do
    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [lease_expires_at: past])
  end

  describe "runners and their tokens" do
    test "a token is shown once and kept only as a hash", %{runner: runner, token: token} do
      assert "sdr_" <> _ = token
      refute runner.token_hash == token
      assert Runners.authenticate(token).id == runner.id
      assert Runners.authenticate(" " <> token <> "\n").id == runner.id
    end

    test "a wrong, blank or revoked token is nobody", %{runner: runner, token: token} do
      assert Runners.authenticate("sdr_wrong") == nil
      assert Runners.authenticate("") == nil
      assert Runners.authenticate(nil) == nil

      {:ok, _} = Runners.delete_runner(runner)
      assert Runners.authenticate(token) == nil
    end

    test "authenticating records when the runner was last seen", %{runner: runner, token: token} do
      assert runner.last_seen_at == nil
      Runners.authenticate(token)
      assert Repo.get!(Runner, runner.id).last_seen_at
    end

    test "a runner made on a sub-board belongs to the whole tree", %{board: board, card: card} do
      {:ok, template} = Boards.find_template("Simple")
      {:ok, sub} = sub_board(card, template)
      {:ok, runner, _} = Runners.create_runner(sub, %{"name" => "r", "pool" => "dev"})
      assert runner.board_id == board.id
    end

    test "a pool must be a plain name", %{board: board} do
      assert {:error, changeset} =
               Runners.create_runner(board, %{"name" => "x", "pool" => "my pool!"})

      assert %{pool: [_]} = errors_on(changeset)

      assert {:ok, runner, _} =
               Runners.create_runner(board, %{"name" => "x", "pool" => " Dev-Box "})

      assert runner.pool == "dev-box"
    end

    test "found by id or by name, only on its own tree", %{board: board, runner: runner} do
      assert {:ok, %{id: id}} = Runners.find_runner(board, runner.id)
      assert id == runner.id
      assert {:ok, %{id: ^id}} = Runners.find_runner(board, "dev-box")

      other = board_fixture()
      assert {:error, :not_found, "runner"} = Runners.find_runner(other, runner.id)
    end
  end

  describe "runner_details/2 (#526)" do
    defp runner_rule(board, pool, attrs \\ %{}) do
      rule_fixture(
        board,
        %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "runner", "pool" => pool}]
        },
        attrs
      )
    end

    test "who made it, the job it holds, how its jobs ended, its latest jobs and its rules",
         ctx do
      %{board: board, todo: todo, owner: owner} = ctx

      {:ok, runner, _} =
        Runners.create_runner(board, %{"name" => "laptop", "pool" => "dev"}, owner)

      second = card_fixture(todo, %{"title" => "Second"})
      {:ok, first_job} = queue(ctx.card)
      {:ok, second_job} = queue(second)
      claimed = Runners.claim(runner)
      assert claimed.id == first_job.id
      {:ok, _} = Runners.finish(runner, first_job.id, %{exit: "0"})
      assert Runners.claim(runner).id == second_job.id

      feeds = runner_rule(board, "dev", %{"name" => "Feeds dev"})
      _other_pool = runner_rule(board, "elsewhere")
      _paused = runner_rule(board, "dev", %{"enabled" => false})

      d = Runners.runner_details(Repo.get!(Runner, runner.id))

      assert d.created_by.id == owner.id
      assert d.api_token == nil
      assert d.current_job.id == second_job.id
      assert d.current_job.card.title == "Second"
      assert d.job_counts == %{"done" => 1, "claimed" => 1}
      assert d.jobs_total == 2
      assert Enum.map(d.recent_jobs, & &1.id) == [second_job.id, first_job.id]
      assert hd(d.recent_jobs).card.title == "Second"
      assert Enum.map(d.rules, & &1.id) == [feeds.id]

      # Another runner's jobs aren't counted as this one's.
      other = Runners.runner_details(ctx.runner)
      assert other.jobs_total == 0
      assert other.recent_jobs == []
      assert other.current_job == nil
      assert other.created_by == nil
    end

    test "limit caps the latest jobs but not the counts", ctx do
      for _ <- 1..3 do
        {:ok, job} = queue(card_fixture(ctx.todo))
        Runners.claim(ctx.runner)
        {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: "1"})
      end

      d = Runners.runner_details(ctx.runner, limit: 2)
      assert length(d.recent_jobs) == 2
      assert d.job_counts == %{"failed" => 3}
      assert d.jobs_total == 3
    end

    test "a Claude session's runner names the API token it works through", ctx do
      {_token, api_token} = Slipdock.Accounts.create_api_token(ctx.owner, "desktop")
      {:ok, session} = Runners.session_runner(ctx.board, "dev", api_token, ctx.owner)

      d = Runners.runner_details(session)
      assert d.api_token.id == api_token.id
      assert d.api_token.label == "desktop"
    end
  end

  describe "queue/2" do
    test "queues a job for the card's tree and pool", %{board: board, card: card} do
      assert {:ok, job} = queue(card)
      assert job.status == "queued"
      assert job.root_board_id == board.id
      assert job.board_id == card.board_id
      assert job.pool == "dev"
      assert job.prompt == "do it"
    end

    test "refuses a pool or kind that isn't a plain name, and an outsize prompt", %{card: card} do
      assert {:error, "pool" <> _} = queue(card, %{pool: "a b"})
      assert {:error, "kind" <> _} = queue(card, %{kind: "rm -rf"})

      assert {:error, "the prompt is over" <> _} =
               queue(card, %{prompt: String.duplicate("x", Runners.limits().max_prompt + 1)})

      assert Repo.aggregate(Job, :count) == 0
    end

    test "one open job per card per rule; another once that one is finished", ctx do
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "log", "message" => "x"}]
        })

      assert {:ok, job} = queue(ctx.card, %{rule: rule})
      assert {:ok, :already_open, same} = queue(ctx.card, %{rule: rule})
      assert same.id == job.id

      # Another rule, or no rule at all, is a job of its own.
      other =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "log", "message" => "x"}]
        })

      assert {:ok, %Job{}} = queue(ctx.card, %{rule: other})

      {:ok, _} = Runners.cancel_job(job)
      assert {:ok, %Job{id: new_id}} = queue(ctx.card, %{rule: rule})
      refute new_id == job.id
    end

    test "the database holds the one-open-job line even when the check is raced", ctx do
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "log", "message" => "x"}]
        })

      {:ok, job} = queue(ctx.card, %{rule: rule})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Job{job | id: nil, status: "queued"})
      end
    end

    test "a full queue refuses more", %{board: board, card: card} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for _ <- 1..Runners.limits().max_open_per_tree,
            do: %{
              board_id: card.board_id,
              root_board_id: board.id,
              card_id: card.id,
              pool: "dev",
              kind: "claude",
              prompt: "x",
              status: "queued",
              attempts: 0,
              inserted_at: now,
              updated_at: now
            }

      Repo.insert_all(Job, rows)
      assert {:error, "the queue is full" <> _} = queue(card)
    end
  end

  describe "claim/2" do
    test "hands out the oldest queued job with a lease, once", ctx do
      {:ok, first} = queue(ctx.card)
      {:ok, second} = queue(ctx.card)

      claimed = Runners.claim(ctx.runner)
      assert claimed.id == first.id
      assert claimed.status == "claimed"
      assert claimed.runner_id == ctx.runner.id
      assert claimed.runner_name == "dev-box"
      assert claimed.attempts == 1
      assert claimed.card.title == "Fix the login page"
      assert DateTime.diff(claimed.lease_expires_at, DateTime.utc_now()) in 80..91
      assert Repo.get!(Runner, ctx.runner.id).current_job_id == first.id

      assert Runners.claim(ctx.runner).id == second.id
      assert Runners.claim(ctx.runner) == nil
    end

    test "two runners asking at once never get the same job", ctx do
      {:ok, job} = queue(ctx.card)
      {:ok, other, _} = Runners.create_runner(ctx.board, %{"name" => "other", "pool" => "dev"})

      results =
        [ctx.runner, other]
        |> Enum.map(fn runner -> Task.async(fn -> Runners.claim(runner) end) end)
        |> Task.await_many()

      assert [%Job{id: id}] = Enum.reject(results, &is_nil/1)
      assert id == job.id
      assert fresh(job).attempts == 1
    end

    test "with nothing queued, waits the time it was given and comes back empty", ctx do
      started = System.monotonic_time(:millisecond)
      assert Runners.claim(ctx.runner, 150) == nil
      assert System.monotonic_time(:millisecond) - started >= 150
    end

    test "a job queued while a runner waits wakes it at once", ctx do
      waiting = Task.async(fn -> Runners.claim(ctx.runner, 5_000) end)
      Process.sleep(50)
      started = System.monotonic_time(:millisecond)
      {:ok, job} = queue(ctx.card)

      assert %Job{id: id} = Task.await(waiting)
      assert id == job.id
      assert System.monotonic_time(:millisecond) - started < 2_000
    end

    test "only the runner's own pool and tree", ctx do
      {:ok, _} = queue(ctx.card, %{pool: "gpu"})

      other_board = board_fixture()
      {:ok, outsider, _} = Runners.create_runner(other_board, %{"name" => "x", "pool" => "gpu"})

      assert Runners.claim(ctx.runner) == nil
      assert Runners.claim(outsider) == nil

      {:ok, gpu, _} = Runners.create_runner(ctx.board, %{"name" => "gpu", "pool" => "gpu"})
      assert %Job{} = Runners.claim(gpu)
    end

    test "a subcard's job goes to the runners of the tree it is in", ctx do
      {:ok, template} = Boards.find_template("Simple")
      {:ok, sub} = sub_board(ctx.card, template)
      sub = Boards.get_board!(sub.id)
      subcard = card_fixture(hd(sub.columns), %{"title" => "Subtask"})

      {:ok, job} = queue(subcard)
      assert job.root_board_id == ctx.board.id
      assert Runners.claim(ctx.runner).id == job.id
    end
  end

  describe "heartbeat/3" do
    setup ctx do
      {:ok, _} = queue(ctx.card)
      %{job: Runners.claim(ctx.runner)}
    end

    test "starts the job running, keeps the log tail and renews the lease", ctx do
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(), 5) |> DateTime.truncate(:second)]
      )

      assert {:ok, :ok} = Runners.heartbeat(ctx.runner, ctx.job.id, "step 1\nstep 2\n")
      job = fresh(ctx.job)
      assert job.status == "running"
      assert job.started_at
      assert job.log_tail == "step 1\nstep 2\n"
      assert DateTime.diff(job.lease_expires_at, DateTime.utc_now()) > 60

      # An empty heartbeat keeps the log it had.
      assert {:ok, :ok} = Runners.heartbeat(ctx.runner, ctx.job.id, "")
      assert fresh(ctx.job).log_tail == "step 1\nstep 2\n"
    end

    test "keeps only the tail of a long log", ctx do
      log = String.duplicate("a", 10_000) <> "THE END"
      Runners.heartbeat(ctx.runner, ctx.job.id, log)
      tail = fresh(ctx.job).log_tail
      assert byte_size(tail) == Runners.limits().max_log
      assert String.ends_with?(tail, "THE END")
    end

    test "says cancel once somebody has asked the job to stop", ctx do
      {:ok, _} = Runners.cancel_job(fresh(ctx.job))
      assert {:ok, :cancel} = Runners.heartbeat(ctx.runner, ctx.job.id, nil)
    end

    test "says cancel for a job that is no longer running", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})
      assert {:ok, :cancel} = Runners.heartbeat(ctx.runner, ctx.job.id, nil)
    end

    test "another runner's job, or no job, is not found", ctx do
      {:ok, other, _} = Runners.create_runner(ctx.board, %{"name" => "other", "pool" => "dev"})
      assert {:error, :not_found} = Runners.heartbeat(other, ctx.job.id, "x")
      assert {:error, :not_found} = Runners.heartbeat(ctx.runner, -1, "x")
      assert {:error, :not_found} = Runners.heartbeat(ctx.runner, "nope", "x")
    end
  end

  describe "finish/3" do
    setup ctx do
      {:ok, _} = queue(ctx.card)
      %{job: Runners.claim(ctx.runner)}
    end

    test "exit 0 is done; the runner is free again and the card's log says so", ctx do
      assert {:ok, job} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0", output: "all good"})
      assert job.status == "done"
      assert job.exit_code == 0
      assert job.output == "all good"
      assert job.finished_at
      assert job.lease_expires_at == nil
      assert Repo.get!(Runner, ctx.runner.id).current_job_id == nil

      assert Repo.exists?(
               from(a in Slipdock.Boards.Activity,
                 where:
                   a.card_id == ^ctx.card.id and a.kind == "runner" and
                     like(a.message, "%done (exit 0)")
               )
             )
    end

    test "any other exit is failed, and 127 says the kind is unknown", ctx do
      assert {:ok, %{status: "failed", exit_code: 127, error: "the runner has no such job kind"}} =
               Runners.finish(ctx.runner, ctx.job.id, %{exit: "127"})
    end

    test "a status the runner names wins over the exit code", ctx do
      assert {:ok, %{status: "timeout", exit_code: 124}} =
               Runners.finish(ctx.runner, ctx.job.id, %{exit: "124", status: "timeout"})
    end

    test "a status it can't name is ignored", ctx do
      assert {:ok, %{status: "failed"}} =
               Runners.finish(ctx.runner, ctx.job.id, %{exit: "2", status: "queued"})
    end

    test "a job somebody cancelled ends cancelled whatever the runner says", ctx do
      {:ok, _} = Runners.cancel_job(fresh(ctx.job))
      assert {:ok, %{status: "cancelled"}} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})
    end

    test "finishing twice changes nothing the second time", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0", output: "first"})

      assert {:ok, %{status: "done", output: "first"}} =
               Runners.finish(ctx.runner, ctx.job.id, %{exit: "1", output: "second"})
    end

    test "only the runner holding the job may finish it", ctx do
      {:ok, other, _} = Runners.create_runner(ctx.board, %{"name" => "other", "pool" => "dev"})
      assert {:error, :not_found} = Runners.finish(other, ctx.job.id, %{exit: "0"})
      assert fresh(ctx.job).status == "claimed"
    end
  end

  describe "cancel_job/1" do
    test "a queued job is cancelled there and then, and never handed out", ctx do
      {:ok, job} = queue(ctx.card)
      assert {:ok, %{status: "cancelled", finished_at: %DateTime{}}} = Runners.cancel_job(job)
      assert Runners.claim(ctx.runner) == nil
    end

    test "a running job is asked to stop", ctx do
      {:ok, _} = queue(ctx.card)
      job = Runners.claim(ctx.runner)

      assert {:ok, %{status: "claimed", cancel_requested_at: %DateTime{}}} =
               Runners.cancel_job(job)
    end

    test "a finished job can't be", ctx do
      {:ok, job} = queue(ctx.card)
      {:ok, job} = Runners.cancel_job(job)
      assert {:error, "job #" <> _} = Runners.cancel_job(job)
    end
  end

  describe "sweep/1" do
    setup ctx do
      {:ok, _} = queue(ctx.card)
      %{job: Runners.claim(ctx.runner)}
    end

    test "leaves a job whose lease is still good", ctx do
      assert Runners.sweep() == 0
      assert fresh(ctx.job).status == "claimed"
    end

    test "puts a job whose lease ran out back in the queue for anybody", ctx do
      expire_lease(ctx.job)
      assert Runners.sweep() == 1

      job = fresh(ctx.job)
      assert job.status == "queued"
      assert job.runner_id == nil
      assert Repo.get!(Runner, ctx.runner.id).current_job_id == nil

      # The runner that lost it hears it is no longer its job.
      assert {:error, :not_found} = Runners.heartbeat(ctx.runner, job.id, "late")

      {:ok, other, _} = Runners.create_runner(ctx.board, %{"name" => "other", "pool" => "dev"})
      assert %Job{attempts: 2} = Runners.claim(other)
    end

    test "after the retry cap, fails the job and flags the card", ctx do
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id),
        set: [attempts: Runners.max_attempts()]
      )

      expire_lease(ctx.job)
      Runners.sweep()

      job = fresh(ctx.job)
      assert job.status == "failed"
      assert job.error =~ "lease ran out"
      assert Runners.claim(ctx.runner) == nil

      card = Boards.get_card!(ctx.card.id) |> Repo.preload(:comments)
      assert "flagged" in card.flags
      assert Enum.any?(card.comments, &(&1.body =~ "Runner job ##{job.id}"))
    end

    test "a job somebody asked to cancel is cancelled, not requeued", ctx do
      {:ok, _} = Runners.cancel_job(ctx.job)
      expire_lease(ctx.job)
      Runners.sweep()
      assert fresh(ctx.job).status == "cancelled"
    end
  end

  describe "tail/2" do
    test "keeps the end, starting on a whole character" do
      assert Runners.tail("short", 10) == "short"
      assert Runners.tail("abcdef", 3) == "def"
      # "é" is two bytes: cutting through it drops the half.
      assert Runners.tail("xé", 1) == ""
      assert Runners.tail("aéb", 3) == "éb"
    end
  end
end
