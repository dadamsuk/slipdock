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
      preferred_envs: [precommit: :test, pre_push: :test]
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
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      pre_push: &pre_push/1
    ]
  end

  @doc """
  The checks CI's `static checks` job and its build run, in the same order
  with the same arguments, for running before a push (`mix pre_push`).
  `test/slipdock/ci_workflow_test.exs` fails when CI runs one this doesn't.

  After the compile and format checks it compiles the CLI (`cli/`, its own Mix
  project) with `--warnings-as-errors`, as CI's `cli` job does, so a CLI
  warning fails here rather than in the pull request (#1964). A step with
  `cd:` runs in that directory, in its own environment (`pre_push_env/1`).

  Then it runs the tests in
  `test/repo_checks.txt` (`repo_checks/0`): the ones that hold the repo's own
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
      {"compile", ["--warnings-as-errors"], cd: "cli"},
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
  """
  def pre_push(args, run \\ &pre_push_run/3) do
    started = System.monotonic_time(:millisecond)

    for step <- pre_push_steps(args) do
      {task, argv, opts} = step_parts(step)
      line = step_line(task, argv, opts)
      Mix.shell().info([:cyan, "==> pre_push: mix #{line}", :reset])
      step_started = System.monotonic_time(:millisecond)

      case run.(task, argv, opts) do
        0 -> Mix.shell().info("    #{seconds(step_started)} s")
        status -> Mix.raise("pre_push: mix #{line} failed (exit #{status})", exit_status: status)
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
  their own (`MIX_TEST_PARTITION`), so they don't wait for the
  `Slipdock.TestRunLock` of a `mix test` running beside them. The compile gets
  it too: the partition is part of the test config, and a step with another
  would recompile what reads it.
  """
  def pre_push_env(opts \\ [])

  # The CLI is its own project: it builds in its own `_build` in its default
  # environment, as CI's cli job does, not in the app's test partition.
  def pre_push_env(cd: _dir) do
    for name <- ~w(MIX_ENV MIX_BUILD_ROOT MIX_BUILD_PATH MIX_TEST_PARTITION MIX_EXS),
        do: {name, nil}
  end

  def pre_push_env([]) do
    [
      {"MIX_ENV", to_string(Mix.env())},
      {"MIX_BUILD_ROOT", pre_push_build_root()},
      {"MIX_TEST_PARTITION", "_pre_push"}
    ]
  end

  defp step_parts({task, argv}), do: {task, argv, []}
  defp step_parts({task, argv, opts}), do: {task, argv, opts}

  defp step_line("test", files, []),
    do: "test (the #{length(files)} files in test/repo_checks.txt)"

  defp step_line(task, argv, cd: dir), do: Enum.join([task | argv], " ") <> " (in #{dir}/)"
  defp step_line(task, argv, []), do: Enum.join([task | argv], " ")

  @doc """
  Runs one step as its own `mix` process and answers with its exit status. A
  `cd:` directory is relative to the project root.
  """
  def pre_push_run(task, argv, opts) do
    {_, status} =
      System.cmd("mix", [task | argv],
        into: IO.stream(),
        stderr_to_stdout: true,
        cd: Path.expand(Keyword.get(opts, :cd, "."), __DIR__),
        env: pre_push_env(opts)
      )

    status
  end

  defp seconds(since),
    do: Float.round((System.monotonic_time(:millisecond) - since) / 1000, 1)
end
