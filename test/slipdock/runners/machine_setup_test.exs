defmodule Slipdock.Runners.MachineSetupTest do
  @moduledoc "Set up this machine with Claude (#2579): the prompt, from the boards' machine-setup pages."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Handbook, Machines, Repo}
  alias Slipdock.Runners.{MachineRunners, MachineSetup}

  @about %{
    "hostname" => "build-box",
    "os" => "linux",
    "arch" => "amd64",
    "fingerprint" => "SHA256:abc"
  }

  setup do
    user = user_fixture("setup-owner@example.com")
    board = board_fixture(%{"name" => "Served", "code" => unique_code()}, owner: user)
    {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
    {:ok, {_machine_key, machine}} = Machines.enrol_with_key(key, @about)
    %{user: user, board: board, machine: machine}
  end

  test "names the board's machine-setup page, and asks for a check, installs, a proof and a write-back",
       ctx do
    {:ok, _} = Handbook.install(ctx.user, ctx.board)
    %{page: code, path: path} = Handbook.local_setup(ctx.board)

    prompt = MachineSetup.prompt(ctx.machine, "https://slipdock.example.com/")

    assert prompt =~
             ~s|enrolled as "build-box" (machine ##{ctx.machine.id}) on https://slipdock.example.com,|

    assert prompt =~ "Served (`#{ctx.board.code}`)"
    assert prompt =~ ~s(`slipdock page section #{code} "#{path}"`)
    assert path == "Testing & tooling/Local setup"
    assert prompt =~ "You are running as the account those jobs run as"
    assert prompt =~ "curl -fsSL https://slipdock.example.com/install.sh | sh"

    for step <- ["1. **Check.**", "2. **Install**", "3. **Prove it.**", "4. **Write back.**"],
        do: assert(prompt =~ step)

    assert prompt =~ "Clone the board's repository into a new scratch directory"
    assert prompt =~ "run its test suite"
    assert prompt =~ ~s(--message "Machine setup on build-box: <what changed>")
    assert prompt =~ "what you changed on the page and why"
    refute prompt =~ "runners work in"
  end

  test "a board without a page is told to write one; the runners' directories are named", ctx do
    {:ok, _} =
      MachineRunners.add_runner(ctx.machine, ctx.board, %{
        "pool" => "build",
        "config" => %{"directory" => "/srv/src/app"}
      })

    prompt = MachineSetup.prompt(ctx.machine, "https://slipdock.example.com")

    assert prompt =~ "Served (`#{ctx.board.code}`): none yet."
    assert prompt =~ "write the page as you go (step 4)"
    assert prompt =~ "The machine's runners work in: `/srv/src/app`."
  end

  test "an archived board is left out; with none served, it says so", ctx do
    {:ok, _} = Slipdock.Boards.archive_board(ctx.board)
    prompt = MachineSetup.prompt(Repo.reload!(ctx.machine), "https://slipdock.example.com")

    refute prompt =~ "Served"
    assert prompt =~ "for no board yet"
    assert prompt =~ "- None: the machine serves no board yet."
  end
end
