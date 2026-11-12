defmodule Slipdock.MixProject do
  use Mix.Project

  def project do
    [
      app: :slipdock,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: Slipdock.Coverage, summary: [threshold: 71]]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Slipdock.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [pre_push: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.20"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      # CommonMark + GFM for wiki pages (comrak, via a precompiled NIF).
      # `SlipdockWeb.Markdown` still renders assistant replies; this is for
      # documents, where tables and fenced code have to work. See docs/wiki.md.
      {:mdex, "~> 0.14"},
      # Reads the HTML of inbound mail (`Slipdock.Inbound.HtmlToMarkdown`).
      # Pure Erlang parser by default: no NIF to fetch or build.
      {:floki, "~> 0.38"},
      {:req, "~> 0.5"},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # WebAuthn: checking passkey registrations and sign-ins (see `Slipdock.Accounts.Passkeys`).
      {:wax_, "~> 0.7.0"},
      # The IANA time zone database, for people's own timezones (recurring
      # cards, snooze). Compiled in; no downloads at runtime.
      {:tz, "~> 0.28.4"},
      # Known advisories in the locked dependencies (`mix deps.audit`, in CI).
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      # The Phoenix security scanner (`mix sobelow`, in CI; settings in .sobelow-conf).
      {:sobelow, "~> 0.18", only: [:dev, :test], runtime: false},
      # The linter, on what a pull request adds (`mix credo diff`, in CI; .credo.exs).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind slipdock", "esbuild slipdock"],
      "assets.deploy": [
        "tailwind slipdock --minify",
        "esbuild slipdock --minify",
        "phx.digest"
      ],
      pre_push: &pre_push/1
    ]
  end

  @doc """
  The checks CI's `static checks` job and its build run, in the same order
  with the same arguments, for running before a push (`mix pre_push`).
  `test/slipdock/ci_workflow_test.exs` fails when CI runs one this doesn't.

  After the compile and format checks it checks the CLI's (`cli/`, its own Mix
  project) formatting, which the app's `mix format` doesn't cover (#2602), and
  compiles it with `--warnings-as-errors`, in the order CI's `cli` job does,
  so a CLI warning or unformatted file fails here rather than in the pull
  request (#1964). A step with `cd:` runs in that directory, in its own
  environment (`pre_push_env/1`).

  Then the runner daemon's (`daemon/`, a Go module) `go vet` and
  `go test -race`, as CI's daemon job does (#2573, #2664): about two minutes
  on macOS, where the race detector slows each helper process the tests
  start. A step with `exec: true` runs its task as
  a program rather than a `mix` task; with no `go` on the PATH it fails and
  says so.

  Then it drops this checkout's own test database (`pre_push_partition/0`),
  so a schema left by another branch's migrations can't carry over (#2115),
  and runs the tests in
  `test/repo_checks.txt` (`repo_checks/0`), which create and migrate it again: the ones that hold the repo's own
  files, docs and skills to a rule, which a builder running only its own
  tests would otherwise first see fail in the pull request's CI.

  Credo lints what the change adds since where it left `origin/main`. Give
  credo's own base instead to check another commit: `mix pre_push
  --from-git-ref <ref>`. `--config-file` is the absolute path, as CI's
  `"$PWD/.credo.exs"`, so the current `.credo.exs` judges both sides.
  """
  def pre_push_steps(credo_base \\ []) do
    credo_base =
      if credo_base == [], do: ["--from-git-merge-base", "origin/main"], else: credo_base

    [
      {"compile", ["--force", "--warnings-as-errors"]},
      {"format", ["--check-formatted"]},
      {"format", ["--check-formatted"], cd: "cli"},
      {"compile", ["--warnings-as-errors"], cd: "cli"},
      {"go", ["vet", "./..."], cd: "daemon", exec: true},
      {"go", ["test", "-race", "./..."], cd: "daemon", exec: true},
      {"ecto.drop", ["--quiet"]},
      {"test", repo_checks()},
      {"hex.audit", []},
      {"deps.audit", []},
      {"sobelow", ["--config"]},
      {"credo", ["diff" | credo_base] ++ ["--config-file", Path.expand(".credo.exs", __DIR__)]}
    ]
  end

  @doc """
  Runs `pre_push_steps/1` in turn, each as its own `mix` process (as CI's
  steps are) in `pre_push_build_root/0`, and stops at the first that exits
  non-zero, with each one's time. `run` is given each step's task, arguments
  and options (`cd:`), and answers with its exit status.

  `mix pre_push --prune` runs no checks: it drops the test databases of
  checkouts that no longer exist (`pre_push_prune/2`), which is all a removed
  worktree leaves behind (#2604). `prune` is what it calls.
  """
  def pre_push(args, run \\ &pre_push_run/3, prune \\ &pre_push_prune/0)

  def pre_push(["--prune"], _run, prune), do: prune.()

  def pre_push(args, run, _prune) do
    started = System.monotonic_time(:millisecond)

    for step <- pre_push_steps(args) do
      {task, argv, opts} = step_parts(step)
      line = step_line(task, argv, opts)
      Mix.shell().info([:cyan, "==> pre_push: #{line}", :reset])
      step_started = System.monotonic_time(:millisecond)

      case run.(task, argv, opts) do
        0 -> Mix.shell().info("    #{seconds(step_started)} s")
        status -> Mix.raise("pre_push: #{line} failed (exit #{status})", exit_status: status)
      end
    end

    Mix.shell().info([:green, "==> pre_push: all checks passed in #{seconds(started)} s", :reset])
  end

  @doc """
  Where the checks build: a build root of their own, so the forced compile
  doesn't rewrite `_build/test` under a `mix test` running beside it. The
  first run compiles the dependencies there once.
  """
  def pre_push_build_root, do: Path.expand("_build/pre_push", __DIR__)

  @repo_checks Path.expand("test/repo_checks.txt", __DIR__)

  @doc """
  The test files `test/repo_checks.txt` lists, which `mix pre_push` runs.
  `test/slipdock/repo_checks_test.exs` says what qualifies and keeps it honest.
  """
  def repo_checks, do: @repo_checks |> File.read!() |> parse_repo_checks() |> Map.fetch!(:tests)

  @doc """
  Parses `test/repo_checks.txt`: one test path per line, `#` comments, and
  `except <path>: <reason>` for a file that looks like a repo check but isn't.
  """
  def parse_repo_checks(text) do
    lines =
      for line <- String.split(text, "\n"),
          line = String.trim(line),
          line != "" and not String.starts_with?(line, "#"),
          do: line

    {exceptions, tests} = Enum.split_with(lines, &String.starts_with?(&1, "except "))

    exceptions =
      Map.new(exceptions, fn "except " <> rest ->
        case String.split(rest, ":", parts: 2) do
          [path, reason] -> {String.trim(path), String.trim(reason)}
          [path] -> {String.trim(path), ""}
        end
      end)

    %{tests: tests, exceptions: exceptions}
  end

  @doc """
  The environment every step runs in. The repo checks use a test database of
  their own (`MIX_TEST_PARTITION`, `pre_push_partition/1`), so they don't wait
  for the `Slipdock.TestRunLock` of a `mix test` running beside them, and one
  per checkout, so another worktree's migrations can't break them (#2115). The
  compile gets it too: the partition is part of the test config, and a step
  with another would recompile what reads it.

  The steps run in `MIX_ENV=test` whatever the `mix pre_push` itself runs in.
  `preferred_envs` makes that `test` only while `MIX_ENV` is unset: set but
  empty, Mix reads it as `dev` (and any other value as itself), and a step
  in `dev` would drop the dev database, which has no partition (#2903).

  `TEST_DATABASE_URL` overrides the partition in `config/test.exs`, so when
  it is set the steps get it with the partition on its database's name
  (`pre_push_database_url/2`) rather than the shared database it names.
  """
  def pre_push_env(opts \\ [], test_database_url \\ System.get_env("TEST_DATABASE_URL"))

  # A program (the daemon's `go`) needs none of Mix's settings.
  def pre_push_env([cd: _dir, exec: true], _test_database_url), do: []

  # The CLI is its own project: it builds in its own `_build` in its default
  # environment, as CI's cli job does, not in the app's test partition.
  def pre_push_env([cd: _dir], _test_database_url) do
    for name <- ~w(MIX_ENV MIX_BUILD_ROOT MIX_BUILD_PATH MIX_TEST_PARTITION MIX_EXS),
        do: {name, nil}
  end

  def pre_push_env([], test_database_url) do
    partition = pre_push_partition()

    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_ROOT", pre_push_build_root()},
      {"MIX_TEST_PARTITION", partition}
    ] ++ pre_push_database_env(test_database_url, partition)
  end

  defp pre_push_database_env(url, _partition) when url in [nil, ""], do: []

  defp pre_push_database_env(url, partition),
    do: [{"TEST_DATABASE_URL", pre_push_database_url(url, partition)}]

  @doc """
  The repo checks' test database partition for the checkout at `root`:
  `_pre_push_` and the first 8 hex digits of the SHA-256 of its path. Two
  worktrees get two databases; one checkout always gets the same one, so
  the steps share it and nothing recompiles.
  """
  def pre_push_partition(root \\ __DIR__) do
    hash = :crypto.hash(:sha256, Path.expand(root)) |> Base.encode16(case: :lower)
    "_pre_push_" <> binary_part(hash, 0, 8)
  end

  @doc """
  `url` with `partition` added to its database's name, as `config/test.exs`
  adds `MIX_TEST_PARTITION` to its default: `postgres://h/slipdock_test` with
  `_pre_push_ab12cd34` is `postgres://h/slipdock_test_pre_push_ab12cd34`. A
  URL already ending in the partition is left as it is.
  """
  def pre_push_database_url(url, partition) do
    uri = URI.parse(url)

    name =
      case uri.path do
        path when path in [nil, "", "/"] -> "slipdock_test"
        "/" <> path -> path
      end

    name = if String.ends_with?(name, partition), do: name, else: name <> partition
    URI.to_string(%{uri | path: "/" <> name})
  end

  @doc """
  Drops the test databases `mix pre_push` left for checkouts that are gone
  (`mix pre_push --prune`, #2604). Each checkout's run makes
  `<base>_pre_push_<hash>` (`pre_push_partition/1`), and nothing drops it
  when its worktree is removed. This lists the server's databases, keeps
  those of the checkouts that still exist (`pre_push_checkouts/0`) and drops
  the rest (`pre_push_stale_databases/3`), saying which. `<base>` is the
  database `TEST_DATABASE_URL` names, else `slipdock_test`.

  A separate clone's database (one `git worktree list` doesn't name) is
  dropped too. That costs nothing: its next `mix pre_push` drops and creates
  it again anyway. One still in use isn't dropped: it says so, carries on
  with the rest, and fails at the end.

  `sql` runs one statement on the server's `postgres` database and answers
  `{:ok, rows}` or `{:error, message}` (`pre_push_sql/1`).
  """
  def pre_push_prune(sql \\ nil, checkouts \\ nil) do
    sql = sql || pre_push_connect()
    checkouts = checkouts || pre_push_checkouts()
    base = pre_push_database_base(System.get_env("TEST_DATABASE_URL"))

    databases =
      case sql.("SELECT datname FROM pg_database ORDER BY datname") do
        {:ok, rows} -> List.flatten(rows)
        {:error, message} -> Mix.raise("pre_push --prune: can't list the databases: #{message}")
      end

    stale = pre_push_stale_databases(databases, checkouts, base)
    if stale == [], do: Mix.shell().info("pre_push --prune: no databases of removed checkouts")

    failed = Enum.reject(stale, &(pre_push_drop(sql, &1) == :ok))

    if failed != [],
      do: Mix.raise("pre_push --prune: couldn't drop #{Enum.join(failed, ", ")}", exit_status: 1)

    stale
  end

  defp pre_push_drop(sql, name) do
    case sql.(~s(DROP DATABASE "#{name}")) do
      {:ok, _} ->
        Mix.shell().info("    dropped #{name}")
        :ok

      {:error, message} ->
        Mix.shell().error("    #{name} not dropped: #{message}")
        :error
    end
  end

  @doc """
  The databases among `databases` that `mix pre_push` made for a checkout
  not in `checkouts`: named `base`, `_pre_push_` and 8 hex digits, whose
  partition is no checkout's. Any other database is left alone.
  """
  def pre_push_stale_databases(databases, checkouts, base \\ "slipdock_test") do
    live = MapSet.new(checkouts, &(base <> pre_push_partition(&1)))
    pattern = ~r/\A#{Regex.escape(base)}_pre_push_[0-9a-f]{8}\z/

    Enum.filter(databases, &(Regex.match?(pattern, &1) and not MapSet.member?(live, &1)))
  end

  @doc """
  The checkouts whose databases `mix pre_push --prune` keeps: this one, and
  every worktree of its repository whose directory still exists
  (`pre_push_worktrees/1`).
  """
  def pre_push_checkouts do
    {out, _status} =
      System.cmd("git", ["worktree", "list", "--porcelain"], cd: __DIR__, stderr_to_stdout: true)

    Enum.uniq([Path.expand(__DIR__) | pre_push_worktrees(out)])
  end

  @doc """
  The worktrees `git worktree list --porcelain` names whose directory still
  exists. A worktree removed by hand stays in the list (as `prunable`) until
  `git worktree prune`; its database goes all the same.
  """
  def pre_push_worktrees(porcelain) do
    for "worktree " <> path <- String.split(porcelain, "\n"),
        File.dir?(path),
        do: Path.expand(path)
  end

  @doc """
  The name the pre_push databases start with: the database `url` names
  (`TEST_DATABASE_URL`), else `slipdock_test`, as `config/test.exs` has it.
  """
  def pre_push_database_base(url) when url in [nil, ""], do: "slipdock_test"

  def pre_push_database_base(url) do
    case URI.parse(url).path do
      path when path in [nil, "", "/"] -> "slipdock_test"
      "/" <> name -> name
    end
  end

  @doc """
  Runs `statement` on the `postgres` database of the server `url` names,
  answering `{:ok, rows}` or `{:error, message}`.
  """
  def pre_push_sql(url, statement) do
    opts = Ecto.Repo.Supervisor.parse_url(url) |> Keyword.put(:database, "postgres")
    {:ok, conn} = Postgrex.start_link(opts)

    try do
      case Postgrex.query(conn, statement, []) do
        {:ok, result} -> {:ok, result.rows || []}
        {:error, error} -> {:error, Exception.message(error)}
      end
    after
      GenServer.stop(conn)
    end
  end

  # The test database's server, from `TEST_DATABASE_URL` or `config/test.exs`.
  defp pre_push_connect do
    Mix.Task.run("loadpaths")
    {:ok, _} = Application.ensure_all_started(:postgrex)

    url =
      case System.get_env("TEST_DATABASE_URL") do
        url when url in [nil, ""] -> Application.fetch_env!(:slipdock, Slipdock.Repo)[:url]
        url -> url
      end

    &pre_push_sql(url, &1)
  end

  defp step_parts({task, argv}), do: {task, argv, []}
  defp step_parts({task, argv, opts}), do: {task, argv, opts}

  defp step_line("test", files, []),
    do: "mix test (the #{length(files)} files in test/repo_checks.txt)"

  defp step_line(program, argv, cd: dir, exec: true),
    do: Enum.join([program | argv], " ") <> " (in #{dir}/)"

  defp step_line(task, argv, cd: dir), do: Enum.join(["mix", task | argv], " ") <> " (in #{dir}/)"
  defp step_line(task, argv, []), do: Enum.join(["mix", task | argv], " ")

  @doc """
  Runs one step as its own `mix` process, or with `exec: true` as the
  program it names, and answers with its exit status. A `cd:` directory is
  relative to the project root.

  The step's output is passed on as bytes (`IO.binstream/0`), not as text:
  under a locale that isn't UTF-8, or with a character split between two
  reads, writing it as text mangles it or crashes, hiding the failure (#2757).
  """
  def pre_push_run(task, argv, opts) do
    if opts[:exec], do: pre_push_exec(task, argv, opts), else: pre_push_mix(task, argv, opts)
  end

  defp pre_push_exec(program, argv, opts) do
    case System.find_executable(program) do
      nil ->
        Mix.shell().error("    #{program} is not on the PATH: install it to run this check")
        127

      path ->
        {_, status} =
          System.cmd(path, argv,
            into: IO.binstream(),
            stderr_to_stdout: true,
            cd: Path.expand(Keyword.fetch!(opts, :cd), __DIR__),
            env: pre_push_env(opts)
          )

        status
    end
  end

  defp pre_push_mix(task, argv, opts) do
    {_, status} =
      System.cmd("mix", [task | argv],
        into: IO.binstream(),
        stderr_to_stdout: true,
        cd: Path.expand(Keyword.get(opts, :cd, "."), __DIR__),
        env: pre_push_env(opts)
      )

    status
  end

  defp seconds(since),
    do: Float.round((System.monotonic_time(:millisecond) - since) / 1000, 1)
end
