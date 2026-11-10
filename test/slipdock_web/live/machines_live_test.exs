defmodule SlipdockWeb.MachinesLiveTest do
  @moduledoc """
  The Machines page (#2572): one machine's page at `/machines/:id`, where
  its owner adds, changes, pauses and removes runners, asks it to update
  now and revokes it; a field outside the machine's ceiling marked with the
  limit; the daemon's refusal shown with its reason and the limit, live;
  and a member of a board the machine serves seeing it and changing
  nothing. Account › Machines lists the ones shared with you too, and
  Connect a runner offers the daemon first.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Machines, Repo, Runners}
  alias Slipdock.Machines.Machine
  alias Slipdock.Runners.{MachineRunners, Runner}

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}
  @dir "/srv/src/app"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Served board", "code" => unique_code()}, owner: user)
    {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
    {:ok, {machine_key, machine}} = Machines.enrol_with_key(key, @about)

    {:ok, machine} =
      MachineRunners.record_ceiling(machine, %{
        "roots" => ["/srv/src"],
        "agents" => ["claude"],
        "max_permission_mode" => "acceptEdits",
        "max_timeout_minutes" => 60,
        "boards" => [board.id],
        "executors" => ["user", "me"]
      })

    %{board: board, machine: machine, key: machine_key}
  end

  defp add(ctx, attrs \\ %{}) do
    {:ok, runner} =
      MachineRunners.add_runner(
        ctx.machine,
        ctx.board,
        Map.merge(%{"pool" => "build", "config" => %{"directory" => @dir}}, attrs)
      )

    runner
  end

  defp page(ctx), do: live(ctx.conn, ~p"/machines/#{ctx.machine.id}")

  describe "the owner" do
    test "sees the machine: state, system, ceiling, executors, runners and the log", ctx do
      runner = add(ctx)

      {:ok, _} =
        MachineRunners.report(ctx.machine, runner, %{"version" => 1, "outcome" => "accepted"})

      {:ok, view, _html} = page(ctx)

      assert has_element?(view, "h1", "build-box")
      assert has_element?(view, "#machine-state", "offline")
      assert has_element?(view, "#page-header", "linux amd64")
      assert has_element?(view, "#machine-ceiling", "/srv/src")
      assert has_element?(view, "#machine-ceiling", "acceptEdits")
      assert has_element?(view, "#machine-ceiling", "60 minutes")
      assert has_element?(view, "#machine-executors", "user, me")
      assert has_element?(view, "#machine-runner-#{runner.id}", "build-box build")
      assert has_element?(view, "#machine-runner-#{runner.id} [data-role=runner-state]", "ready")
      assert has_element?(view, "#machine-runner-#{runner.id}", @dir)
      assert has_element?(view, "#machine-log", "accepted")
      refute has_element?(view, "#machine-owner")

      # Heard from just now: online.
      Machines.authenticate(ctx.key)
      {:ok, view, _html} = page(ctx)
      assert has_element?(view, "#machine-state", "online")
    end

    test "adds a runner, and changes it", ctx do
      {:ok, view, _html} = page(ctx)
      assert has_element?(view, "#machine-runners-none")

      view |> element("#machine-add-runner") |> render_click()

      assert has_element?(
               view,
               "#machine-runner-form input[name='runner[directory]'][value='/srv/src']"
             )

      view
      |> form("#machine-runner-form",
        runner: %{"pool" => "build", "name" => "builder", "directory" => @dir}
      )
      |> render_submit()

      assert [runner] = MachineRunners.list_runners(ctx.machine)
      assert runner.name == "builder"
      assert runner.config["directory"] == @dir
      assert has_element?(view, "#machine-notice", "builder saved")
      assert has_element?(view, "#machine-runner-#{runner.id}", "waiting for the machine")

      view |> element("#machine-runner-#{runner.id} button", "Edit") |> render_click()

      view
      |> form("#machine-runner-form", runner: %{"timeout_minutes" => "30", "model" => "sonnet"})
      |> render_submit()

      runner = Repo.get!(Runner, runner.id)
      assert runner.config["timeout_minutes"] == 30
      assert runner.config["model"] == "sonnet"
      assert runner.config_version == 2
    end

    test "a container runner names its image and its network (#2577)", ctx do
      {:ok, view, _html} = page(ctx)
      view |> element("#machine-add-runner") |> render_click()
      assert has_element?(view, "#machine-runner-form select[name='runner[network]']")

      for {image, says} <- [
            {"", "image is required when executor is container"},
            {"--privileged", "image must be an image name"}
          ] do
        view
        |> form("#machine-runner-form",
          runner: %{
            "pool" => "build",
            "directory" => @dir,
            "executor" => "container",
            "image" => image
          }
        )
        |> render_submit()

        assert has_element?(view, "#machine-notice", says)
        assert MachineRunners.list_runners(ctx.machine) == []
      end

      view
      |> form("#machine-runner-form",
        runner: %{
          "pool" => "build",
          "directory" => @dir,
          "executor" => "container",
          "image" => "slipdock-agent:1",
          "network" => "off"
        }
      )
      |> render_submit()

      assert [runner] = MachineRunners.list_runners(ctx.machine)
      assert runner.config["image"] == "slipdock-agent:1"
      assert runner.config["network"] == "off"

      assert has_element?(
               view,
               "#machine-runner-#{runner.id} [data-role=runner-image]",
               "slipdock-agent:1, network off"
             )
    end

    test "a bad setting is refused on the page, and nothing is saved", ctx do
      {:ok, view, _html} = page(ctx)
      view |> element("#machine-add-runner") |> render_click()

      view
      |> form("#machine-runner-form", runner: %{"pool" => "build", "directory" => "relative/dir"})
      |> render_submit()

      assert has_element?(view, "#machine-notice", "directory must be an absolute path")
      assert has_element?(view, "#machine-runner-form")
      assert MachineRunners.list_runners(ctx.machine) == []
    end

    test "a field outside the ceiling is marked with its limit as it is typed", ctx do
      {:ok, view, _html} = page(ctx)
      view |> element("#machine-add-runner") |> render_click()
      refute has_element?(view, "#machine-runner-form-outside")

      view
      |> form("#machine-runner-form",
        runner: %{
          "timeout_minutes" => "240",
          "permission_mode" => "bypassPermissions",
          "directory" => "/home/elsewhere"
        }
      )
      |> render_change()

      assert has_element?(view, "#machine-runner-form-outside", "will refuse this")

      assert has_element?(view, "#machine-runner-form p", "timeout 240 minutes is over 60")

      assert has_element?(
               view,
               "#machine-runner-form p",
               "permission mode bypassPermissions is above acceptEdits"
             )

      assert has_element?(
               view,
               "#machine-runner-form p",
               "directory /home/elsewhere is not under /srv/src"
             )

      # The browser marks fields not yet touched as unused; a limit shows anyway.
      render_change(view, "form_change", %{
        "runner" => %{"timeout_minutes" => "240", "_unused_timeout_minutes" => ""}
      })

      render_change(view, "form_change", %{"runner" => %{"timeout_minutes" => "241"}})
      assert has_element?(view, "#machine-runner-form p", "timeout 241 minutes is over 60")
    end

    test "the machine's refusal shows live, with the reason and the limit", ctx do
      runner = add(ctx)
      {:ok, view, _html} = page(ctx)
      refute has_element?(view, "#machine-runner-#{runner.id}-rejection")

      {:ok, runner} =
        MachineRunners.set_runner(runner, %{"config" => %{"timeout_minutes" => 240}})

      assert has_element?(view, "#machine-runner-#{runner.id}", "Outside the ceiling")

      {:ok, _} =
        MachineRunners.report(ctx.machine, runner, %{
          "version" => runner.config_version,
          "outcome" => "rejected",
          "reason" => "timeout_minutes 240 is over this machine's ceiling of 60"
        })

      assert has_element?(
               view,
               "#machine-runner-#{runner.id} [data-role=runner-state]",
               "rejected"
             )

      assert has_element?(
               view,
               "#machine-runner-#{runner.id}-rejection",
               "The machine refused v2"
             )

      assert has_element?(view, "#machine-runner-#{runner.id}-rejection", "ceiling of 60")

      assert has_element?(
               view,
               "#machine-runner-#{runner.id}-rejection",
               "timeout 240 minutes is over 60"
             )

      assert has_element?(view, "#machine-log", "rejected")
      assert has_element?(view, "#machine-runner-#{runner.id}-rejection", "accepted no settings")

      # Once it has accepted a version, the refusal says that one still runs.
      {:ok, runner} = MachineRunners.set_runner(runner, %{"config" => %{"timeout_minutes" => 30}})

      {:ok, _} =
        MachineRunners.report(ctx.machine, runner, %{"version" => 3, "outcome" => "accepted"})

      {:ok, runner} = MachineRunners.set_runner(runner, %{"config" => %{"timeout_minutes" => 90}})

      {:ok, _} =
        MachineRunners.report(ctx.machine, runner, %{
          "version" => 4,
          "outcome" => "rejected",
          "reason" => "over the ceiling"
        })

      assert has_element?(view, "#machine-runner-#{runner.id}-rejection", "It still runs v3")
    end

    test "pauses, resumes and removes a runner", ctx do
      runner = add(ctx)
      {:ok, view, _html} = page(ctx)

      view |> element("#machine-runner-#{runner.id} button", "Pause") |> render_click()
      assert Repo.get!(Runner, runner.id).paused_at
      assert has_element?(view, "#machine-runner-#{runner.id} [data-role=runner-state]", "paused")

      view |> element("#machine-runner-#{runner.id} button", "Resume") |> render_click()
      refute Repo.get!(Runner, runner.id).paused_at

      view |> element("#machine-runner-#{runner.id} button", "Remove") |> render_click()
      assert Repo.get(Runner, runner.id) == nil
      refute has_element?(view, "#machine-runner-#{runner.id}")
      assert has_element?(view, "#machine-notice", "finishes the job it holds")
    end

    test "shows the job a runner is working on", ctx do
      runner = add(ctx)
      [_backlog, todo | _] = ctx.board.columns
      card = card_fixture(todo, %{"title" => "Building now"})
      {:ok, _job} = Runners.queue(card, %{pool: "build", kind: "claude", prompt: "Do"})
      {:ok, claimer} = Runners.authenticate_machine(ctx.key, runner.id)
      %{} = Runners.claim(claimer)

      {:ok, view, _html} = page(ctx)

      assert has_element?(
               view,
               "#machine-runner-#{runner.id} [data-role=runner-job]",
               "Building now"
             )

      assert has_element?(
               view,
               "#machine-runner-#{runner.id} [data-role=runner-state]",
               "working"
             )
    end

    test "Set up this machine with Claude shows the prompt to copy, until it's revoked (#2579)",
         ctx do
      {:ok, view, _html} = page(ctx)

      assert has_element?(view, "#machine-setup summary", "Set up this machine with Claude")
      assert has_element?(view, "#machine-setup-prompt", ~s(enrolled as "build-box"))
      assert has_element?(view, "#machine-setup-prompt", "Prove it.")
      assert has_element?(view, "#machine-setup-prompt-copy[data-target=machine-setup-prompt]")

      view |> element("#machine-revoke") |> render_click()
      refute has_element?(view, "#machine-setup")
    end

    test "renames the machine; a blank name is refused and changes nothing (#2666)", ctx do
      {:ok, view, _html} = page(ctx)
      refute has_element?(view, "#machine-rename", "hostname")

      view |> form("#machine-rename", %{name: "Silverbox"}) |> render_submit()
      assert Repo.get!(Machine, ctx.machine.id).name == "Silverbox"
      assert has_element?(view, "#machine-notice", "the machine is now Silverbox")
      assert has_element?(view, "h1", "Silverbox")
      assert has_element?(view, "#machine-rename", "hostname build-box")
      assert page_title(view) =~ "Silverbox"

      view |> form("#machine-rename", %{name: "   "}) |> render_submit()
      assert has_element?(view, "#machine-notice", "give the machine a name")
      assert Repo.get!(Machine, ctx.machine.id).name == "Silverbox"
    end

    test "update now and revoke", ctx do
      {:ok, view, _html} = page(ctx)

      view |> element("#machine-update-now") |> render_click()
      assert Repo.get!(Machine, ctx.machine.id).update_requested_at
      assert has_element?(view, "#machine-update-asked")

      view |> element("#machine-revoke") |> render_click()
      assert Machine.revoked?(Repo.get!(Machine, ctx.machine.id))
      assert has_element?(view, "#machine-state", "revoked")
      refute has_element?(view, "#machine-add-runner")
      refute has_element?(view, "#machine-update-now")
    end
  end

  describe "the probe (#2580)" do
    defp probe_claimed(ctx, runner) do
      {:ok, claimer} = Runners.authenticate_machine(ctx.key, runner.id)
      claimer = Runners.report_kinds(claimer, "claude,verify,merge,probe")
      %Runners.Job{} = job = Runners.claim(claimer)
      {claimer, job}
    end

    test "the owner sends one, and the page follows it to green", ctx do
      runner = add(ctx)
      {:ok, view, _html} = page(ctx)
      refute has_element?(view, "#machine-runner-#{runner.id}-probe")

      view |> element("#machine-runner-#{runner.id} [data-role=probe-runner]") |> render_click()
      assert has_element?(view, "#machine-notice", "Probe sent to #{runner.name}")

      assert has_element?(
               view,
               "#machine-runner-#{runner.id}-probe[data-result=pending]",
               "waiting for the machine"
             )

      # The daemon takes it and reports, and the page shows each step live.
      {claimer, job} = probe_claimed(ctx, runner)
      {:ok, :ok} = Runners.heartbeat(claimer, job.id, "ok   directory: fine\n")

      assert has_element?(
               view,
               "#machine-runner-#{runner.id}-probe[data-result=pending]",
               "Probe ##{job.id} running"
             )

      {:ok, _} = Runners.finish(claimer, job.id, %{exit: "0", output: "probe: green\n"})

      assert has_element?(
               view,
               "#machine-runner-#{runner.id}-probe[data-result=green]",
               "Probe passed"
             )
    end

    test "a red probe shows how it ended and its log", ctx do
      runner = add(ctx)
      {:ok, _} = Runners.Probe.send_probe(ctx.machine, runner)
      {claimer, job} = probe_claimed(ctx, runner)

      {:ok, _} =
        Runners.finish(claimer, job.id, %{exit: "1", output: "FAIL gh: gh is not signed in\n"})

      {:ok, view, _html} = page(ctx)

      assert has_element?(
               view,
               "#machine-runner-#{runner.id}-probe[data-result=red]",
               "Probe failed"
             )

      assert has_element?(
               view,
               "#machine-runner-#{runner.id}-probe [data-role=probe-log]",
               "FAIL gh: gh is not signed in"
             )
    end

    test "a paused runner has no Probe button, and probing it anyway says why", ctx do
      runner = add(ctx)
      {:ok, _} = MachineRunners.pause_runner(runner)
      {:ok, view, _html} = page(ctx)

      refute has_element?(view, "#machine-runner-#{runner.id} [data-role=probe-runner]")
      render_click(view, "probe_runner", %{"id" => runner.id})
      assert has_element?(view, "#machine-notice", "is paused: resume it, then probe it")
    end
  end

  describe "a member of a board it serves" do
    setup ctx do
      member = user_fixture("member@example.com")
      {:ok, _} = Access.grant(ctx.board, member, "read", ctx.user)
      %{member_conn: conn_as(member)}
    end

    test "sees it, and no control to change it", ctx do
      {:ok, member_view, _} = live(ctx.member_conn, ~p"/machines/#{ctx.machine.id}")
      refute has_element?(member_view, "#machine-setup")

      runner = add(ctx)
      private = board_fixture(%{"name" => "Private", "code" => unique_code()}, owner: ctx.user)

      machine =
        Repo.update!(Ecto.Changeset.change(ctx.machine, board_ids: [ctx.board.id, private.id]))

      {:ok, hidden} =
        MachineRunners.add_runner(machine, private, %{
          "pool" => "secret",
          "name" => "hidden",
          "config" => %{"directory" => @dir}
        })

      {:ok, _} =
        MachineRunners.report(machine, hidden, %{
          "version" => 1,
          "outcome" => "rejected",
          "reason" => "the private board's secret"
        })

      {:ok, view, _html} = live(ctx.member_conn, ~p"/machines/#{ctx.machine.id}")

      assert has_element?(view, "#machine-owner", "you see it as a member")
      assert has_element?(view, "#machine-runner-#{runner.id}")
      assert has_element?(view, "#machine-ceiling", "/srv/src")
      refute has_element?(view, "#machine-add-runner")
      refute has_element?(view, "#machine-update-now")
      refute has_element?(view, "#machine-revoke")
      refute has_element?(view, "#machine-rename")
      # A forged rename is refused too.
      render_hook(view, "rename", %{"name" => "theirs now"})
      assert Repo.get!(Machine, ctx.machine.id).name == "build-box"
      refute has_element?(view, "#machine-runner-#{runner.id} button")
      # Only the runners of boards they're on: not the owner's other work.
      refute has_element?(view, "#machine-runner-#{hidden.id}")
      refute has_element?(view, "#machine-log", "the private board's secret")
      refute has_element?(view, "#machine-log", "hidden")
      {:ok, owner_view, _html} = page(ctx)
      assert has_element?(owner_view, "#machine-runner-#{hidden.id}")
      assert has_element?(owner_view, "#machine-log", "the private board's secret")
    end

    test "sees a runner's probe result", ctx do
      runner = add(ctx)
      {:ok, probe} = Runners.Probe.send_probe(ctx.machine, runner)

      Repo.update_all(from(j in Runners.Job, where: j.id == ^probe.id),
        set: [status: "done", exit_code: 0, finished_at: DateTime.utc_now(:second)]
      )

      {:ok, view, _html} = live(ctx.member_conn, ~p"/machines/#{ctx.machine.id}")
      assert has_element?(view, "#machine-runner-#{runner.id}-probe[data-result=green]")
      refute has_element?(view, "#machine-runner-#{runner.id} [data-role=probe-runner]")
    end

    test "an event sent anyway changes nothing", ctx do
      runner = add(ctx)
      {:ok, view, _html} = live(ctx.member_conn, ~p"/machines/#{ctx.machine.id}")

      render_click(view, "pause_runner", %{"id" => runner.id})
      render_click(view, "probe_runner", %{"id" => runner.id})
      render_click(view, "revoke", %{})
      render_click(view, "update_now", %{})

      refute Repo.get!(Runner, runner.id).paused_at
      machine = Repo.get!(Machine, ctx.machine.id)
      refute Machine.revoked?(machine)
      refute machine.update_requested_at
      assert Runners.Probe.latest([runner]) == %{}
      assert has_element?(view, "#machine-notice", "Only the machine's owner changes it")
    end

    test "Account › Machines lists it under the machines serving your boards", ctx do
      {:ok, view, _html} = live(ctx.member_conn, ~p"/account/machines")

      assert has_element?(
               view,
               "#shared-machine-#{ctx.machine.id} a[href='/machines/#{ctx.machine.id}']"
             )

      assert has_element?(view, "#shared-machines", "Served board")
    end
  end

  test "someone else's machine isn't found, and the page goes back to the list", ctx do
    stranger = conn_as(user_fixture("stranger@example.com"))

    assert {:error, {:live_redirect, %{to: "/account/machines"}}} =
             live(stranger, ~p"/machines/#{ctx.machine.id}")

    assert {:error, {:live_redirect, %{to: "/account/machines"}}} =
             live(ctx.conn, ~p"/machines/not-a-number")
  end

  test "Account › Machines links each machine to its page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account/machines")
    assert has_element?(view, "#machine-#{ctx.machine.id} a[href='/machines/#{ctx.machine.id}']")
    refute has_element?(view, "#shared-machines")
  end

  describe "Connect a runner (#2572)" do
    test "offers the daemon first, and its steps make an enrolment key for the board", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")
      view |> element("#connect-runner") |> render_click()

      assert has_element?(view, "#runner-wizard input[value=daemon][checked]")
      assert has_element?(view, "#wizard-daemon-note")
      refute has_element?(view, "#runner-wizard input[name='wizard[cwd]']")
      assert has_element?(view, "#runner-wizard", "sde_YOUR_ENROLMENT_KEY")

      # First in the list the wizard draws, as well as the one picked.
      assert hd(Slipdock.Runners.Setup.scenarios()) == "daemon"

      html =
        view
        |> form("#runner-wizard", wizard: %{"scenario" => "daemon", "pool" => "build"})
        |> render_submit()

      [key] = Regex.run(~r/sde_[A-Za-z0-9_-]{20,}/, html)
      assert html =~ "slipdock-runner init --server"
      assert Runners.list_runners(ctx.board) == []

      assert {:ok, {_machine_key, machine}} = Machines.enrol_with_key(key, @about)
      assert machine.board_ids == [ctx.board.id]
    end
  end
end
