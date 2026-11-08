defmodule Slipdock.Runners.Drift do
  @moduledoc """
  Skill and CLI drift on the machines that run agents (#1795, W-2310 §Sweeps
  and static checks).

  A machine's installed copies of the packaged skills (`priv/skills`, their
  one source) can be older than what the server serves, and so can its
  `slipdock` CLI, so a pass can follow stale instructions. On every claim a
  runner says what it has:

      X-Runner-Skills: slipdock=<sha256>,slipdock-loop=<sha256>,…
      X-Runner-CLI: <sha256>

  each the SHA-256 of a skill's installed `SKILL.md` (line endings as LF) or
  of the CLI file. This module keeps them on the runner, compares them with
  what this server serves (the packaged `SKILL.md`s, and the escript
  `/cli/SHA256SUMS` publishes), and keeps one alert on the runner's board
  while anything differs, cleared once it is current again.

  **Report only.** Nothing here touches a machine: the server never calls
  out to a runner (ARCH-5). Installed copies are installed from the server,
  never edited by hand (#2048): a runner that keeps itself current puts the
  server's skills in place before each job (`keep_skills` in
  `priv/runner/slipdock-runner`, `Update-Skills` in its PowerShell twin), so
  its drift clears on the next claim; anywhere else, the install one-liner
  (`docs/agents.md` §Install the skills) brings them up to date.
  """

  import Ecto.Query

  alias Slipdock.Automations
  alias Slipdock.Automations.Alert
  alias Slipdock.Repo
  alias Slipdock.Runners.Runner

  @sha ~r/\A[0-9a-f]{64}\z/
  @skill_name ~r/\Aslipdock[a-z0-9_-]{0,40}\z/
  @max_skills 20

  @doc """
  Parses `X-Runner-Skills`: `name=sha` pairs separated by commas or spaces,
  names starting `slipdock`. Nil for a missing header (the runner said
  nothing), a map otherwise (empty when it has none installed); a pair that
  doesn't read is dropped.
  """
  def parse_skills(nil), do: nil

  def parse_skills(header) when is_binary(header) do
    header
    |> String.split([",", " "], trim: true)
    |> Enum.take(@max_skills)
    |> Enum.flat_map(fn pair ->
      with [name, sha] <- String.split(pair, "=", parts: 2),
           name = String.downcase(String.trim(name)),
           sha = String.downcase(String.trim(sha)),
           true <- Regex.match?(@skill_name, name) and Regex.match?(@sha, sha) do
        [{name, sha}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  Parses `X-Runner-CLI`: a SHA-256, or `none` when the machine has no CLI.
  Nil when it is missing or doesn't read.
  """
  def parse_cli(nil), do: nil

  def parse_cli(header) when is_binary(header) do
    value = header |> String.trim() |> String.downcase()
    if value == "none" or Regex.match?(@sha, value), do: value
  end

  @doc """
  Keeps what `runner` said on its claim (the two headers, raw) and returns
  the runner with it, its alert raised or cleared to match. A header it
  didn't send leaves that part as it was.
  """
  def report(%Runner{} = runner, skills_header, cli_header) do
    skills = parse_skills(skills_header)
    cli = parse_cli(cli_header)

    changes =
      []
      |> then(
        &if(is_map(skills) and skills != runner.skills, do: [{:skills, skills} | &1], else: &1)
      )
      |> then(&if(is_binary(cli) and cli != runner.cli_sha, do: [{:cli_sha, cli} | &1], else: &1))

    runner =
      case changes do
        [] ->
          runner

        changes ->
          Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: changes)
          struct(runner, changes)
      end

    sync_alert(runner)
  end

  ## Comparing ------------------------------------------------------------------

  @doc """
  What the runner's skills are against `served` (name to SHA-256, see
  `served_skills/0`): `:unknown` when it never said, `:current`, or
  `{:drifted, names}` for each served skill installed with other contents.
  A skill this server doesn't serve, or one not installed, isn't drift.
  """
  def skills_state(%Runner{skills: nil}, _served), do: :unknown

  def skills_state(%Runner{skills: skills}, served) do
    drifted =
      for {name, sha} <- Enum.sort(skills),
          Map.has_key?(served, name),
          served[name] != sha,
          do: name

    if drifted == [], do: :current, else: {:drifted, drifted}
  end

  @doc """
  What the runner's CLI is against `served` (the escript's SHA-256, or nil
  when this server has none to give): `:current`, `:old`, `:none` (the
  machine has no CLI) or `:unknown` (it never said, or there is nothing to
  compare with).
  """
  def cli_state(%Runner{cli_sha: nil}, _served), do: :unknown
  def cli_state(%Runner{cli_sha: "none"}, _served), do: :none
  def cli_state(%Runner{}, nil), do: :unknown
  def cli_state(%Runner{cli_sha: sha}, sha), do: :current
  def cli_state(%Runner{}, _served), do: :old

  @doc "Both states for `runner`, against what this server serves now."
  def states(%Runner{} = runner) do
    %{skills: skills_state(runner, served_skills()), cli: cli_state(runner, served_cli())}
  end

  @doc "Whether either state is drift: a skill that differs, or an old CLI."
  def drifted?(%{skills: {:drifted, _}}), do: true
  def drifted?(%{cli: :old}), do: true
  def drifted?(_), do: false

  @doc "Words for a state: `current`, `drifted (slipdock-loop)`, `old`, `unknown`."
  def describe({:drifted, names}), do: "drifted (#{Enum.join(names, ", ")})"
  def describe(state) when is_atom(state), do: Atom.to_string(state)

  @doc """
  The packaged skills' SHA-256s: each `priv/skills/<name>/SKILL.md`, as a
  runner computes it from its installed copy.
  """
  def served_skills do
    dir = Slipdock.Skills.dir()

    cached({:skills, dir}, fn ->
      for skill <- Slipdock.Skills.list(),
          {:ok, text} <- [File.read(Path.join([dir, skill.name, "SKILL.md"]))],
          into: %{},
          do: {skill.name, sha256(String.replace(text, "\r\n", "\n"))}
    end)
  end

  @doc """
  The SHA-256 of the CLI escript this server serves (`/cli/SHA256SUMS`), or
  nil when it was built without one (a server run from a checkout).
  """
  def served_cli do
    path = escript_path()

    case File.stat(path) do
      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        cached({:cli, path, size, mtime}, fn -> file_sha(path) end)

      _ ->
        nil
    end
  end

  defp file_sha(path) do
    case File.read(path) do
      {:ok, body} -> sha256(body)
      _ -> nil
    end
  end

  @doc "Where the CLI escript is (configurable, so the tests can stand a file in)."
  def escript_path do
    Application.get_env(:slipdock, :cli_escript) ||
      Application.app_dir(:slipdock, "priv/cli/slipdock.escript")
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # A release's files don't change while it runs, and a claim comes every
  # few seconds from each runner; the key changes when the file does.
  defp cached(key, fun) do
    key = {__MODULE__, key}

    case :persistent_term.get(key, :missing) do
      :missing ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  ## The alert ------------------------------------------------------------------

  @doc """
  Raises the runner's drift alert if it has drifted and has none, and clears
  it once it hasn't: one alert a drift, on the runner's board. Returns the
  runner with `drift_alert_id` to match.
  """
  def sync_alert(%Runner{} = runner) do
    states = states(runner)
    alert = runner.drift_alert_id && Repo.get(Alert, runner.drift_alert_id)

    cond do
      drifted?(states) and is_nil(alert) -> raise_alert(runner, states)
      not drifted?(states) and alert -> clear_alert(runner, alert)
      true -> runner
    end
  end

  defp raise_alert(runner, states) do
    parts =
      [
        match?({:drifted, _}, states.skills) && "skills #{describe(states.skills)}",
        states.cli == :old && "CLI old"
      ]
      |> Enum.filter(& &1)

    attrs = %{
      "board_id" => runner.board_id,
      "severity" => "warning",
      "title" => "Runner #{runner.name} has drifted from this server: #{Enum.join(parts, ", ")}",
      "body" =>
        "Its installed copies differ from what this server serves, so passes on it may " <>
          "follow stale instructions. A runner that keeps itself current installs this " <>
          "server's skills before its next job; otherwise run the install one-liner " <>
          "again (skills are never edited by hand). This alert clears itself once the " <>
          "runner reports them current."
    }

    case Automations.raise_alert(attrs) do
      {:ok, alert} -> set_alert(runner, alert.id)
      {:error, _} -> runner
    end
  end

  defp clear_alert(runner, alert) do
    Automations.delete_alert(alert.id)
    set_alert(runner, nil)
  end

  defp set_alert(runner, id) do
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [drift_alert_id: id])
    %{runner | drift_alert_id: id}
  end
end
