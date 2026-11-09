defmodule Slipdock.Runners.ProbeTest do
  @moduledoc """
  The probe (#2580): a job of kind `probe` with no card, sent to one
  machine runner, claimed by it ahead of its pool's queue and by no other,
  leased, heartbeated, finished and swept like any job, without touching a
  card; its prompt the server's drift verdict; green or red with its log.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Machines, Repo, Runners}
  alias Slipdock.Runners.{Job, MachineRunners, Probe, Runner}

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Served", "code" => unique_code()}, owner: user)
    {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
    {:ok, {machine_key, machine}} = Machines.enrol_with_key(key, @about)
    %{user: user, board: board, machine: machine, key: machine_key}
  end

  defp add(ctx, pool \\ "build") do
    {:ok, runner} =
      MachineRunners.add_runner(ctx.machine, ctx.board, %{
        "pool" => pool,
        "name" => "#{pool}-#{System.unique_integer([:positive])}",
        "config" => %{"directory" => "/srv/src/app"}
      })

    runner
  end

  # The runner as its daemon's claim makes it: the machine key, and the
  # kinds it said it takes.
  defp claimer(ctx, runner, kinds \\ "claude,verify,merge,probe") do
    {:ok, r} = Runners.authenticate_machine(ctx.key, runner.id)
    Runners.report_kinds(r, kinds)
  end

  defp queue_card(ctx, pool \\ "build") do
    [_backlog, todo | _] = ctx.board.columns
    card = card_fixture(todo, %{"title" => "Queued"})
    {:ok, job} = Runners.queue(card, %{pool: pool, kind: "claude", prompt: "Do"})
    job
  end

  describe "sending one" do
    test "queues a probe with no card for that runner, and only one at a time", ctx do
      runner = add(ctx)
      MachineRunners.subscribe(ctx.machine)

      assert {:ok, %Job{} = job} = Probe.send_probe(ctx.machine, runner)
      assert job.kind == "probe"
      assert job.card_id == nil
      assert job.for_runner_id == runner.id
      assert job.board_id == ctx.board.id and job.root_board_id == ctx.board.id
      assert job.pool == runner.pool and job.status == "queued"
      assert_receive {:probe_changed, id} when id == job.id

      # A second send while it waits is the same probe.
      assert {:ok, %Job{id: same}} = Probe.send_probe(ctx.machine, runner)
      assert same == job.id
      assert Repo.aggregate(from(j in Job, where: j.kind == "probe"), :count) == 1
    end

    test "is refused for a paused runner, a revoked machine and another machine's runner",
         ctx do
      runner = add(ctx)
      {:ok, paused} = MachineRunners.pause_runner(runner)

      assert {:error, :invalid, "#{paused.name} is paused: resume it, then probe it"} ==
               Probe.send_probe(ctx.machine, paused)

      {:ok, other_key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      {:ok, {_, other}} = Machines.enrol_with_key(other_key, @about)

      assert {:error, :invalid, "that runner is not one of " <> _} =
               Probe.send_probe(other, runner)

      live = add(ctx)
      {:ok, revoked} = Machines.revoke_machine(ctx.machine)

      assert {:error, :invalid, "#{revoked.name} is revoked, so it takes no probe"} ==
               Probe.send_probe(revoked, live)

      assert Repo.aggregate(from(j in Job, where: j.kind == "probe"), :count) == 0
    end
  end

  describe "claiming it" do
    test "its runner takes it ahead of the pool's queue; nobody else in the pool does", ctx do
      runner = add(ctx)
      other = add(ctx)
      card_job = queue_card(ctx)
      {:ok, probe} = Probe.send_probe(ctx.machine, runner)

      # Another runner of the same pool gets the card's job, never the probe.
      assert %Job{id: id} = Runners.claim(claimer(ctx, other))
      assert id == card_job.id
      assert Runners.claim(claimer(ctx, other)) == nil

      assert %Job{id: probe_id, card_id: nil, status: "claimed"} =
               Runners.claim(claimer(ctx, runner))

      assert probe_id == probe.id
      assert Repo.get!(Runner, runner.id).current_job_id == probe.id
      assert %{status: "claimed", runner_id: rid, attempts: 1} = Repo.get!(Job, probe.id)
      assert rid == runner.id
    end

    test "goes first even while the pool is paused, then the pool's jobs wait", ctx do
      runner = add(ctx)
      _card_job = queue_card(ctx)
      {:ok, _} = Runners.pause(ctx.board, %{"pool" => "build", "reason" => "deploy"}, ctx.user)
      {:ok, probe} = Probe.send_probe(ctx.machine, runner)

      assert %Job{id: id} = Runners.claim(claimer(ctx, runner))
      assert id == probe.id
      assert Runners.claim(claimer(ctx, runner)) == nil
    end

    test "a daemon that doesn't say it takes probes isn't handed one", ctx do
      runner = add(ctx)
      {:ok, probe} = Probe.send_probe(ctx.machine, runner)

      assert Runners.claim(claimer(ctx, runner, "claude,verify,merge")) == nil
      assert Repo.get!(Job, probe.id).status == "queued"
      refute Probe.takes_probes?(%Runner{kinds: nil})
    end

    test "a waiting claim wakes when a probe is sent", ctx do
      runner = add(ctx)
      me = claimer(ctx, runner)
      task = Task.async(fn -> Runners.claim(me, 5_000) end)
      # Let the claim subscribe and wait.
      Process.sleep(100)
      {:ok, probe} = Probe.send_probe(ctx.machine, runner)

      assert %Job{id: id} = Task.await(task, 6_000)
      assert id == probe.id
    end

    test "its prompt is the server's drift verdict, and no card goes with it", ctx do
      runner = add(ctx)
      Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [cli_sha: "none"])
      {:ok, _} = Probe.send_probe(ctx.machine, runner)
      job = Runners.claim(claimer(ctx, runner))

      prompt = Runners.claimed_prompt(job)
      assert prompt =~ "probe of runner #{runner.name} (##{runner.id})\n"
      assert prompt =~ "\nskills: unknown\n"
      assert prompt =~ "\ncli: none\n"
      assert Runners.claim_context(job) == %{wait: nil, handoff: nil, profile: nil}
      assert Probe.prompt(%Job{runner_id: nil}) == "probe\n"
    end
  end

  describe "running and ending it" do
    setup ctx do
      runner = add(ctx)
      {:ok, probe} = Probe.send_probe(ctx.machine, runner)
      me = claimer(ctx, runner)
      %Job{} = Runners.claim(me)
      Map.merge(ctx, %{runner: runner, probe: probe, me: me})
    end

    test "heartbeats carry its log; done is green, with the log it sent", ctx do
      MachineRunners.subscribe(ctx.machine)
      assert {:ok, :ok} = Runners.heartbeat(ctx.me, ctx.probe.id, "ok   directory: …\n")
      assert_receive {:probe_changed, _}
      running = Repo.get!(Job, ctx.probe.id)
      assert running.status == "running"
      assert Probe.result(running) == :pending
      assert Probe.log(running) == "ok   directory: …\n"

      assert {:ok, done} =
               Runners.finish(ctx.me, ctx.probe.id, %{exit: "0", output: "probe: green\n"})

      assert done.status == "done"
      assert Probe.result(done) == :green
      assert Probe.log(done) == "probe: green\n"
      assert Repo.get!(Runner, ctx.runner.id).current_job_id == nil
      # Nothing went on a card: no activity, no handoff, no finding.
      said = "%job ##{ctx.probe.id}%"
      refute Repo.exists?(from(a in Slipdock.Boards.Activity, where: like(a.message, ^said)))

      assert Repo.aggregate(Slipdock.Boards.Handoff, :count) == 0
      assert %Job{id: id} = Probe.latest([ctx.runner])[ctx.runner.id]
      assert id == ctx.probe.id
    end

    test "a failed probe is red, and a send after it is a fresh probe", ctx do
      assert {:ok, failed} =
               Runners.finish(ctx.me, ctx.probe.id, %{exit: "1", output: "FAIL gh: …\n"})

      assert Probe.result(failed) == :red
      assert Repo.aggregate(Slipdock.Findings.Finding, :count) == 0

      assert {:ok, fresh} = Probe.send_probe(ctx.machine, ctx.runner)
      assert fresh.id != ctx.probe.id
      assert %{id: latest} = Probe.latest([ctx.runner])[ctx.runner.id]
      assert latest == fresh.id
    end

    test "a lease that runs out goes back in the queue, then fails, touching no card", ctx do
      expire = fn ->
        Repo.update_all(from(j in Job, where: j.id == ^ctx.probe.id),
          set: [lease_expires_at: ~U[2020-01-01 00:00:00Z]]
        )

        Runners.sweep()
      end

      assert expire.() == 1
      assert %{status: "queued", runner_id: nil} = Repo.get!(Job, ctx.probe.id)

      Repo.update_all(from(j in Job, where: j.id == ^ctx.probe.id),
        set: [status: "running", attempts: Runners.max_attempts()]
      )

      assert expire.() == 1

      assert %{status: "failed", error: "no runner finished it" <> _} =
               Repo.get!(Job, ctx.probe.id)

      assert Probe.result(Repo.get!(Job, ctx.probe.id)) == :red
    end

    test "a removed runner takes its probes with it", ctx do
      Repo.delete!(Repo.get!(Runner, ctx.runner.id))
      refute Repo.get(Job, ctx.probe.id)
    end
  end

  describe "a probe beside the board's own work" do
    test "an open probe doesn't empty the queries that leave out cards with open jobs", ctx do
      runner = add(ctx)
      {:ok, _probe} = Probe.send_probe(ctx.machine, runner)
      [_backlog, todo | _] = ctx.board.columns
      card = card_fixture(todo, %{"title" => "Top"})

      # A feed passes over cards with an open job (`NOT IN` their card ids):
      # the probe's NULL card id must not make it pass over every card.
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "list_top", "column" => "To Do"},
          "actions" => [%{"type" => "runner", "pool" => "build"}]
        })

      assert [%Job{card_id: card_id}] = Repo.all(from(j in Job, where: j.rule_id == ^rule.id))
      assert card_id == card.id
    end
  end

  test "latest/1 of no runners is empty, and result/1 and log/1 read any job" do
    assert Probe.latest([]) == %{}
    assert Probe.result(%Job{status: "timeout"}) == :red
    assert Probe.result(%Job{status: "queued"}) == :pending
    assert Probe.result(%Job{status: "claimed"}) == :pending
    assert Probe.result(%Job{status: "running"}) == :pending
    assert Probe.log(%Job{output: nil, log_tail: nil}) == ""
  end
end
