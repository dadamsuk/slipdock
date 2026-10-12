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
  alias SlipdockCLI.Sync.{Engine, Remote, State}

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
    state = State.save(root, State.new(HTTP.base_url(), vault, Engine.hostname()))
    IO.puts("bound #{dir} to the vault #{Render.bold(vault["name"])}")
    pass(root, state, o)
  end

  def run("sync", ["init"], _o), do: fail("usage: slipdock sync init DIR --vault V")

  def run("sync", [], o), do: run("sync", ["."], o)

  def run("sync", [dir], o) do
    root = root!(dir)
    pass(root, load!(root), o)
  end

  def run("sync", _args, _o),
    do: fail("usage: slipdock sync init DIR --vault V | sync [DIR]")

  ## A pass -------------------------------------------------------------------

  # The lock is let go before anything halts: `System.halt/1` skips `after`.
  defp pass(root, state, o) do
    result =
      with_lock(root, fn ->
        case Engine.run(root, state, {Remote, state["vault"]["id"]}) do
          {:ok, state, report} ->
            State.save(root, state)
            if o[:json], do: Render.json(json(report, state)), else: print(report, state)
            if report.errors != [], do: :errors, else: :ok

          {:error, :unauthorized} ->
            {:fail, "not signed in to #{HTTP.origin(HTTP.base_url())}. Run `slipdock auth`."}

          {:error, msg} ->
            {:fail, "sync didn't run: #{msg}"}
        end
      end)

    case result do
      :ok -> :ok
      :errors -> System.halt(1)
      {:fail, msg} -> fail(msg)
    end
  end

  @doc false
  def print(report, state) do
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

    IO.puts(Render.dim("#{state["vault"]["name"]}: #{counts}"))
  end

  defp json(report, state) do
    %{
      "vault" => state["vault"],
      "cursor" => state["cursor"],
      "report" => Map.new(report, fn {k, v} -> {to_string(k), Enum.map(v, &stringify/1)} end)
    }
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

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
