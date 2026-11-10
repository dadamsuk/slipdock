defmodule Slipdock.MachinesDocsTest do
  @moduledoc """
  Machines' enrolment (#2570) is written where people and agents look: the
  agent guide and `docs/agents.md` name the endpoints, the machine key and
  why there is no MCP door; README and the agents help page say what a
  machine key is; and the manual's account page lists Account › Machines
  and the approval page. A machine's runners (#2571) are described the same
  way in the guide and `docs/agents.md`, every config field named, and so
  is Set up this machine with Claude (#2579).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the guide and docs/agents.md describe enrolment the same way" do
    for text <- [SlipdockWeb.APIGuide.markdown(), read("docs/agents.md")] do
      for part <- [
            "POST /api/machines/enrol",
            "POST\n/api/machines/enrol/token",
            "/account/machines/approve",
            "POST /api/machines/enrolment-keys",
            "GET /api/machine",
            "DELETE /api/machines/:id",
            "/api/machines/enrolment/approve",
            "sdm_",
            "Not over MCP",
            "slipdock machines"
          ] do
        assert text =~ String.replace(part, "\n", " ") or text =~ part, "missing #{part}"
      end
    end
  end

  test "the guide and docs/agents.md describe a machine's runners the same way (#2571)" do
    for text <- [SlipdockWeb.APIGuide.markdown(), read("docs/agents.md")] do
      text = String.replace(text, ~r/\s+/, " ")

      for part <- [
            "POST /api/machines/:id/runners",
            "PATCH /api/machines/:id/runners/:runner_id",
            "GET /api/machine/config?version=N&wait=S",
            "PUT /api/machine/ceiling",
            "POST /api/machine/runners/:runner_id/report",
            "There is no command field",
            "X-Runner-Id"
          ] do
        assert text =~ part, "missing #{part}"
      end

      for field <- Slipdock.Runners.Config.fields(), do: assert(text =~ "`#{field}`")
    end
  end

  test "README and the agents help page say what a machine key is" do
    assert read("README.md") =~ "A machine running runners has a key of its own, not your token."

    help = read("lib/slipdock_web/live/help_live/agents.ex")
    assert help =~ ~s(id="help-machines")
    assert help =~ "which is not an API\n        token"
  end

  test "the manual's account page lists Machines and the approval page" do
    manual = read("docs/manual/accounts-and-sharing.md")
    assert manual =~ "**Machines** (`/account/machines`)"
    assert manual =~ "/account/machines/approve"
  end

  test "the Machines page is written up everywhere a reader looks (#2572)" do
    for text <- [SlipdockWeb.APIGuide.markdown(), read("docs/agents.md")] do
      text = String.replace(text, ~r/\s+/, " ")

      for part <- [
            "/machines/:id",
            "POST /api/machines/:id/runners/:runner_id/pause",
            "POST /api/machines/:id/update",
            "update_requested_at",
            "`shared`",
            "A member's write is a 403",
            "add-runner|set-runner|pause-runner|resume-runner|rm-runner|update",
            "`scenario` `daemon`",
            "`enrolment_key`"
          ] do
        assert text =~ part, "missing #{part}"
      end
    end

    manual = read("docs/manual/machines.md")
    assert manual =~ "### The Machines page"
    assert manual =~ "slipdock machine add-runner"
    assert read("docs/manual.md") =~ "(manual/machines.md#the-machines-page)"
    assert read("docs/agents.md") =~ "| A machine with the daemon |"
    assert read("README.md") =~ "machine with the runner daemon (offered first"

    help = read("lib/slipdock_web/live/help_live/agents.ex")
    assert help =~ ~s(id="help-machine-page")
    assert help =~ ~s(id="help-scenario-daemon")
    assert read("cli/help.txt") =~ "machine add-runner <id> <board> --pool P --dir D"
  end

  test "the probe is written up everywhere a reader looks (#2580)" do
    for text <- [SlipdockWeb.APIGuide.markdown(), read("docs/agents.md")] do
      text = String.replace(text, ~r/\s+/, " ")

      for part <- [
            "**The probe** (#2580)",
            "POST /api/machines/:id/runners/:runner_id/probe",
            "`probe: null`",
            "`X-Job-Kind: probe`",
            "`skills: current`",
            "slipdock machine probe <machine> <runner> [--wait]"
          ] do
        assert text =~ part, "missing #{part}"
      end
    end

    manual = read("docs/manual/machines.md")
    assert manual =~ "### Probing a runner"
    assert manual =~ "slipdock machine probe 4 build-box-build --wait"
    assert read("docs/manual.md") =~ "(manual/machines.md#probing-a-runner)"
    assert read("lib/slipdock_web/live/help_live/agents.ex") =~ ~s(id="help-machine-probe")
    assert read("cli/help.txt") =~ "machine probe <id> <runner> [--wait]"

    assert read("priv/skills/slipdock/SKILL.md") =~
             "slipdock machine probe <id> <runner> [--wait]"
  end

  test "Set up this machine with Claude is written up everywhere a reader looks (#2579)" do
    for text <- [SlipdockWeb.APIGuide.markdown(), read("docs/agents.md")] do
      text = String.replace(text, ~r/\s+/, " ")

      for part <- [
            "**Set up this machine with Claude**",
            "GET /api/machines/:id/setup-prompt",
            "slipdock machine setup-prompt <id>",
            "GET /api/machine/setup-prompt",
            "Testing & tooling §Local setup"
          ] do
        assert text =~ part, "missing #{part}"
      end
    end

    manual = read("docs/manual/machines.md")
    assert manual =~ "### Set up this machine with Claude"
    assert manual =~ "slipdock-runner setup"
    assert manual =~ "init --no-setup"
    assert read("docs/manual.md") =~ "(manual/machines.md#set-up-this-machine-with-claude)"
    assert read("README.md") =~ "*Set up this machine with Claude* there"
    assert read("lib/slipdock_web/live/help_live/agents.ex") =~ ~s(id="help-machine-setup")
    assert read("cli/help.txt") =~ "machine setup-prompt <id>"
    assert read("priv/skills/slipdock/SKILL.md") =~ "slipdock machine setup-prompt <id>"
  end

  test "every copy of Connect a runner's scenario list names each scenario (#2572)" do
    scenarios = Slipdock.Runners.Setup.scenarios()
    flag = "[--scenario #{Enum.join(scenarios, "|")}]"

    for path <- ["cli/help.txt", "priv/skills/slipdock/SKILL.md"],
        do: assert(read(path) =~ flag, "#{path} lacks #{flag}")

    guide = String.replace(SlipdockWeb.APIGuide.markdown(), ~r/\s+/, " ")
    listed = Enum.map_join(scenarios, ", ", &"`#{&1}`")
    assert guide =~ "with `scenario` (#{listed})"

    runners = String.replace(read("docs/manual/runners.md"), ~r/\s+/, " ")
    assert runners =~ "where the work should happen — a machine with the runner daemon"
    for s <- scenarios, do: assert(runners =~ "`#{s}`", "runners.md's CLI row lacks #{s}")

    assert read("priv/skills/slipdock/SKILL.md") =~ "slipdock machine add-runner"
  end

  test "the manual says how to read a machine from its own files (#2652)" do
    manual = read("docs/manual/machines.md") |> String.replace(~r/\s+/, " ")

    for part <- [
          "slipdock-runner status [--json]",
          "slipdock-runner log [--level debug|info|warn|error] [--since DUR] [-n N] [--follow]",
          "slipdock-runner log --runner NAME | --job ID [-n N] [--follow]",
          "slipdock-runner config [--effective | --json]",
          "`daemon-state.json`",
          "`jobs/<runner>/job.json`",
          "`daemon.log.1`",
          "`log_level`",
          "`run --log-level`",
          "It exits non-zero when the daemon isn't running or a runner's settings were refused"
        ] do
      assert manual =~ part, "missing #{part}"
    end
  end
end
