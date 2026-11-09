defmodule Slipdock.Runners.MachineSetup do
  @moduledoc """
  *Set up this machine with Claude* (#2579): a prompt for Claude Code on an
  enrolled machine, run as the account its jobs run as, that sets the
  machine up from each served board's own machine-setup page (the handbook's
  Testing & tooling §Local setup, `Slipdock.Handbook.local_setup/1`).

  It asks for a check, the installs, a proof (a clean clone of the
  repository, set up as the page says, and its suite run) and a write-back:
  the page corrected where it was wrong, and a report of what was done. The
  daemon fetches it at the end of `slipdock-runner init` (and with
  `slipdock-runner setup`) and launches `claude` with it; the Machines page,
  the API and the CLI show it to paste. It is text only: the server decides
  no command (ARCH-5), and the person watches the session it starts.
  """

  import Ecto.Query

  alias Slipdock.Boards.Board
  alias Slipdock.Handbook
  alias Slipdock.Machines.Machine
  alias Slipdock.Repo
  alias Slipdock.Runners.MachineRunners

  @doc """
  The prompt for `machine` as it is now: the boards it serves (archived ones
  left out) and its runners' directories, on the server at `base_url`.
  """
  def prompt(%Machine{} = machine, base_url) do
    ids = machine.board_ids || []

    boards =
      Repo.all(
        from(b in Board, where: b.id in ^ids and is_nil(b.archived_at), order_by: [asc: b.id])
      )

    directories =
      machine
      |> MachineRunners.list_runners()
      |> Enum.map(&(&1.config || %{})["directory"])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    text(machine, boards, directories, base_url)
  end

  @doc """
  Each of `boards`' machine-setup page, as `{board, %{page:, path:}}`, or
  `{board, nil}` for a board whose handbook has none (or no handbook).
  """
  def pages(boards), do: Enum.map(boards, &{&1, Handbook.local_setup(&1)})

  @doc """
  The prompt for `machine`, serving `boards`, whose runners work in
  `directories`, on the server at `base_url`.
  """
  def text(%Machine{} = machine, boards, directories, base_url) do
    base_url = String.trim_trailing(to_string(base_url), "/")
    pages = pages(boards)

    """
    Set up this machine to run Slipdock jobs, from the board's own machine-setup page.

    This machine is enrolled as "#{machine.name}" (machine ##{machine.id}) on #{base_url}, and its runner daemon (`slipdock-runner`) runs coding-agent jobs for #{served(boards)}. You are running as the account those jobs run as: whatever you install, sign in to or clone here is what a job will find, so install for this account and don't switch to another one.

    The machine-setup #{if length(pages) == 1, do: "page", else: "pages"}:

    #{page_lines(pages)}

    Read them with the `slipdock` CLI. If it isn't installed, `curl -fsSL #{base_url}/install.sh | sh` installs it and the skills, and `slipdock auth` signs it in (I approve it in my browser).#{directory_line(directories)}

    Work in this order, and tell me what you find at each step before going on:

    1. **Check.** For everything the page names (tools and their versions, services, logins, environment), check what this machine has before changing anything. Also check `git`, `gh auth status`, the agent (`claude --version`) and `slipdock-runner doctor`. List what is there, what is missing and what is the wrong version.
    2. **Install** what is missing, as the page says, for this account. Ask me before anything that needs `sudo`, changes a system service or another account, or costs money; never put a secret in a file others can read.
    3. **Prove it.** Clone the board's repository into a new scratch directory (from the page, or from a runner's directory above; ask me if neither says), set it up from that clean checkout as the page says, and run its test suite. It is proved when the suite passes. If it fails, find out whether the machine or the code is the cause, and fix the machine's part.
    4. **Write back.** Correct the page where it was wrong or left something out, so the next machine is set up from it alone: edit only that section (`slipdock page section <page> "<path>" --body - --message "Machine setup on #{machine.name}: <what changed>"`, its current text first), written as how things are now, with nothing personal in it (no names, hostnames, addresses or tokens). A board with no page gets a `### A runner machine` under its Testing & tooling page's `## Local setup`. Then tell me what you checked, what you installed, the suite's result, and what you changed on the page and why.

    Don't change the runner daemon's files (its ceiling, local file and key), and don't start jobs: when this is done I add the machine's runners on its page.
    """
  end

  defp served([]), do: "no board yet (a runner added on its page serves one)"
  defp served(boards), do: Enum.map_join(boards, ", ", &board_name/1)

  defp board_name(%Board{} = board),
    do: if(board.code, do: "#{board.name} (`#{board.code}`)", else: board.name)

  defp page_lines([]),
    do:
      "- None: the machine serves no board yet. Set it up for what its runners will need, and ask me which repository to prove it with."

  defp page_lines(pages) do
    Enum.map_join(pages, "\n", fn
      {board, %{page: code, path: path}} ->
        "- #{board_name(board)}: `slipdock page section #{code} \"#{path}\"`"

      {board, nil} ->
        "- #{board_name(board)}: none yet. Its handbook has no Testing & tooling §Local setup, so set the machine up from the repository's own README or contributing guide, and write the page as you go (step 4)."
    end)
  end

  defp directory_line([]), do: ""

  defp directory_line(directories),
    do:
      "\n\nThe machine's runners work in: " <>
        Enum.map_join(directories, ", ", &"`#{&1}`") <> "."
end
