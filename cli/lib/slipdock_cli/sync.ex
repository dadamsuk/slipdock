defmodule SlipdockCLI.Sync do
  @moduledoc false

  # `slipdock sync`: a vault mirrored both ways to a local folder that stays
  # a valid Obsidian vault (W-103 R2). The server is the source of truth; the
  # folder is a working copy, and anything that writes a text file into it
  # writes into the vault.
  #
  #   sync init DIR --vault V    bind a folder to a vault, then run once
  #   sync [DIR]                 one pass, both ways
  #
  # The folder's memory is `DIR/.slipdock/state.json` (`SlipdockCLI.Sync.State`);
  # the pass itself is `SlipdockCLI.Sync.Engine`.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render
  alias SlipdockCLI.Sync.{Engine, Remote, Service, State, Watch}

  @commands ~w(sync)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("sync", ["init", dir], o) do
    if is_nil(o[:vault]), do: fail("say which vault: slipdock sync init #{dir} --vault V")
    root = Path.expand(dir)

    if File.exists?(State.path(root)) and not o[:force] do
      {:ok, state} = State.load(root)

      fail(
        "#{dir} is already a mirror of #{state["vault"]["name"]} — run `slipdock sync #{dir}`, " <>
          "or init again with --force to bind it afresh"
      )
    end

    vault =
      case HTTP.get("/vaults/#{enc(o[:vault])}") do
        {:ok, %{"vault" => vault}} -> vault
        error -> out(error, o, fn _ -> :ok end)
      end

    if vault["mappings"] == [],
      do:
        fail(
          "#{vault["name"]} has nothing mapped yet — `slipdock vault map` a board into it first"
        )

    File.mkdir_p!(root)
    State.save(root, State.new(HTTP.base_url(), vault, Engine.hostname()))
    IO.puts("bound #{dir} to the vault #{Render.bold(vault["name"])}")
    pass(root, o)
  end

  def run("sync", ["init"], _o), do: fail("usage: slipdock sync init DIR --vault V")

  def run("sync", ["service", action | rest], o) when action in ~w(install uninstall print) do
    root = root!(List.first(rest) || ".")

    plan =
      Service.plan(
        :os.type(),
        root,
        Service.command(),
        System.user_home!(),
        System.get_env("PATH") || ""
      )

    service(action, plan, o)
  end

  def run("sync", ["service" | _], _o),
    do: fail("usage: slipdock sync service install|uninstall|print [DIR]")

  def run("sync", [], o), do: run("sync", ["."], o)

  def run("sync", [dir], o) do
    root = root!(dir)
    load!(root)

    if o[:watch], do: watch(root, o), else: pass(root, o)
  end

  def run("sync", _args, _o),
    do: fail("usage: slipdock sync init DIR --vault V | sync [DIR] [--watch [--interval S]]")

  ## A pass -------------------------------------------------------------------

  # The lock is let go before anything halts: `System.halt/1` skips `after`.
  defp pass(root, o) do
    case pass_once(root, o) do
      {:ok, _state, []} -> :ok
      {:ok, _state, _errors} -> System.halt(1)
      {:fail, msg} -> fail(msg)
    end
  end

  # One pass, the state read afresh (a watcher's last pass changed it) and
  # saved after. Never halts: a watcher carries on past a failed pass.
  defp pass_once(root, o) do
    with_lock(root, fn ->
      {:ok, state} = State.load(root)

      case Engine.run(root, state, {Remote, state["vault"]["id"]}) do
        {:ok, state, report} ->
          State.save(root, state)
          if o[:json], do: Render.json(json(report, state)), else: print(report, state, o)
          {:ok, state, report.errors}

        {:error, :unauthorized} ->
          {:fail, "not signed in to #{HTTP.origin(HTTP.base_url())}. Run `slipdock auth`."}

        {:error, msg} ->
          {:fail, "sync didn't run: #{msg}"}
      end
    end)
  end

  defp watch(root, o) do
    interval = max(o[:interval] || 10, 1)

    # Stopped by the service manager (or Ctrl-C's cousin, `kill`): let go of
    # the folder and leave quietly rather than with a crash report. A pass cut
    # short is harmless: files are only ever renamed into place, and the next
    # pass finds both sides agreeing where they do.
    System.trap_signal(:sigterm, :slipdock_sync, fn ->
      File.rm(Path.join([root, State.dir_name(), "lock"]))
      System.halt(0)
    end)

    IO.puts(Render.dim("watching #{root} (the server every #{interval}s); Ctrl-C to stop"))

    pass = fn ->
      case pass_once(root, Keyword.put(o, :stamp, true)) do
        {:ok, state, _errors} ->
          state["cursor"]

        {:fail, msg} ->
          IO.puts(:stderr, "#{stamp()} error: #{msg}")
          nil
      end
    end

    {:ok, state} = State.load(root)
    cursor = pass.() || state["cursor"]

    Watch.loop(root, cursor, pass, &Remote.changes(state["vault"]["id"], &1),
      interval_ms: interval * 1000
    )
  end

  defp stamp, do: Time.utc_now() |> Time.truncate(:second) |> Time.to_iso8601()

  @doc false
  def print(report, state, o \\ []) do
    # A watcher says when, and only when something happened.
    quiet? = Enum.all?(report, fn {_k, v} -> v == [] end)

    if o[:stamp] && quiet?, do: :ok, else: print_report(report, state, o)
  end

  defp print_report(report, state, o) do
    for %{path: p} <- report.sent, do: IO.puts("↑ " <> p)
    for %{path: p} <- report.received, do: IO.puts("↓ " <> p)
    for %{from: f, path: p} <- report.moved, do: IO.puts("→ #{f} → #{p}")

    for %{path: p} <- report.archived,
        do: IO.puts("✕ #{p} " <> Render.dim("(archived on the server)"))

    for %{path: p} <- report.removed,
        do: IO.puts("✕ #{p} " <> Render.dim("(archived elsewhere, removed here)"))

    for c <- report.conflicts,
        do: IO.puts("! #{c.path} changed on both sides: yours is now #{c.copy}")

    for e <- report.errors, do: IO.puts(:stderr, "error: #{e.path}: #{e.error}")

    counts =
      [:sent, :received, :moved, :archived, :removed, :conflicts]
      |> Enum.map_join(", ", &"#{&1} #{length(Map.fetch!(report, &1))}")

    when_ = if o[:stamp], do: stamp() <> " ", else: ""
    IO.puts(Render.dim("#{when_}#{state["vault"]["name"]}: #{counts}"))
  end

  defp json(report, state) do
    %{
      "vault" => state["vault"],
      "cursor" => state["cursor"],
      "report" => Map.new(report, fn {k, v} -> {to_string(k), Enum.map(v, &stringify/1)} end)
    }
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  ## Running in the background ----------------------------------------------

  defp service("print", plan, _o) do
    if plan.file do
      IO.puts(Render.dim("# " <> plan.file))
      IO.write(plan.content)
    end

    IO.puts(Render.dim("# then:"))
    Enum.each(plan.install, &IO.puts(Enum.map_join(&1, " ", fn w -> shell_word(w) end)))
  end

  defp service("install", plan, _o) do
    if plan.file do
      File.mkdir_p!(Path.dirname(plan.file))
      File.write!(plan.file, plan.content)
      IO.puts("wrote #{plan.file}")
    end

    # `launchctl unload` of an agent not yet loaded fails, and is meant to.
    [last | earlier] = Enum.reverse(plan.install)
    Enum.each(Enum.reverse(earlier), &run_cmd(&1, false))

    case run_cmd(last, true) do
      :ok ->
        IO.puts("started #{plan.name}; it starts again when you log in. Logs: #{plan.logs}")

      {:error, msg} ->
        fail(
          "#{msg}\n  the service file is written; start it by hand with: " <> Enum.join(last, " ")
        )
    end
  end

  defp service("uninstall", plan, _o) do
    Enum.each(plan.uninstall, &run_cmd(&1, false))
    if plan.file, do: File.rm(plan.file)
    IO.puts("stopped and removed #{plan.name}")
  end

  defp run_cmd([cmd | args], strict?) do
    case System.find_executable(cmd) do
      nil ->
        if strict?, do: {:error, "#{cmd} is not on this machine"}, else: :ok

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {_, 0} ->
            :ok

          {out, code} ->
            if strict?, do: {:error, "#{cmd} failed (#{code}): #{String.trim(out)}"}, else: :ok
        end
    end
  end

  defp shell_word(word) do
    if String.match?(word, ~r/[^\w\/.\-=:]/),
      do: "'" <> String.replace(word, "'", "'\\''") <> "'",
      else: word
  end

  ## The folder ---------------------------------------------------------------

  @doc false
  def root!(dir) do
    case State.find_root(dir) do
      {:ok, root} ->
        root

      :error ->
        fail("#{dir} is not a synced folder — start one with: slipdock sync init DIR --vault V")
    end
  end

  # A mirror talks to the server it was bound to, whatever the url file now
  # says, unless --url says otherwise for this one run.
  @doc false
  def load!(root) do
    case State.load(root) do
      {:ok, state} ->
        if is_nil(System.get_env("SLIPDOCK_URL")) and state["url"],
          do: System.put_env("SLIPDOCK_URL", state["url"])

        state

      _ ->
        fail("#{State.path(root)} can't be read — init the folder again with --force")
    end
  end

  # One pass at a time per folder: a watcher and a hand-run sync must not
  # both move the same files. A lock older than ten minutes is a pass that
  # died, and is taken over.
  @doc false
  def with_lock(root, fun) do
    lock = Path.join([root, State.dir_name(), "lock"])
    File.mkdir_p!(Path.dirname(lock))

    stale? =
      case File.stat(lock, time: :posix) do
        {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime > 600
        _ -> false
      end

    if stale?, do: File.rm(lock)

    case File.open(lock, [:write, :exclusive]) do
      {:ok, device} ->
        IO.write(device, System.pid())
        File.close(device)

        try do
          fun.()
        after
          File.rm(lock)
        end

      {:error, :eexist} ->
        {:fail, "another sync is running on #{root} (#{lock}); try again in a moment"}
    end
  end
end
