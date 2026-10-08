defmodule SlipdockWeb.RunnerInstallTest do
  # `/runner/install.sh`, fetched as anybody would and run under `sh` into a
  # throwaway HOME: what it writes, with what permissions, for each service
  # manager — and that the bytes served are the bytes the checksum names.
  use SlipdockWeb.ConnCase, async: true

  @moduletag :anonymous

  setup %{conn: conn} do
    home = Path.join(System.tmp_dir!(), "slipdock-install-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    script = Path.join(home, "install.sh")
    File.write!(script, conn |> get("/runner/install.sh") |> response(200))
    %{home: home, script: script}
  end

  defp install(ctx, args) do
    System.cmd("sh", [ctx.script | args],
      env: [{"HOME", ctx.home}, {"XDG_CONFIG_HOME", nil}],
      stderr_to_stdout: true
    )
  end

  @base ~w(--url https://slipdock.example --token sdr_secret --no-start)

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  # What the config sets, read back by sourcing it the way the runner does.
  defp sourced(ctx, var) do
    config = Path.join(ctx.home, ".config/slipdock-runner/config")
    {out, 0} = System.cmd("sh", ["-c", ". \"$1\"; printf '%s' \"$#{var}\"", "sh", config])
    out
  end

  test "served as text, the same bytes every time, matching SHA256SUMS", %{conn: conn} do
    install = conn |> get("/runner/install.sh") |> response(200)
    runner = build_conn() |> get("/runner/slipdock-runner") |> response(200)
    sums = build_conn() |> get("/runner/SHA256SUMS") |> response(200)

    assert install == build_conn() |> get("/runner/install.sh") |> response(200)

    assert sums =~
             (:crypto.hash(:sha256, install) |> Base.encode16(case: :lower)) <> "  install.sh\n"

    assert sums =~
             (:crypto.hash(:sha256, runner) |> Base.encode16(case: :lower)) <>
               "  slipdock-runner\n"

    # Nothing about this server or this caller is written into it.
    refute install =~ "www.example.com"
    # The runner travels inside the installer, whole.
    assert String.contains?(install, runner)
    refute install =~ "__SLIPDOCK_RUNNER__"
  end

  test "writes the runner, a mode-600 config and a systemd user unit", ctx do
    {out, 0} =
      install(ctx, @base ++ ~w(--pool dev-box --cwd /srv/work --timeout 900 --service systemd))

    bin = Path.join(ctx.home, ".local/bin/slipdock-runner")
    config = Path.join(ctx.home, ".config/slipdock-runner/config")
    unit = Path.join(ctx.home, ".config/systemd/user/slipdock-runner.service")

    assert File.read!(bin) == SlipdockWeb.RunnerInstallController.files()["slipdock-runner"]
    assert mode(bin) == 0o755
    assert mode(config) == 0o600
    assert out =~ "start it with: systemctl --user enable --now slipdock-runner"

    assert sourced(ctx, "SLIPDOCK_URL") == "https://slipdock.example"
    assert sourced(ctx, "SLIPDOCK_RUNNER_TOKEN") == "sdr_secret"
    assert sourced(ctx, "POOL") == "dev-box"
    assert sourced(ctx, "WORKDIR") == "/srv/work"
    assert sourced(ctx, "JOB_TIMEOUT") == "900"
    assert File.read!(config) =~ "job_claude() {"
    assert File.read!(config) =~ "job_echo() {"

    unit = File.read!(unit)
    assert unit =~ "ExecStart=#{bin}\n"
    assert unit =~ "Description=Slipdock runner (pool dev-box)"
    assert unit =~ "Restart=always"
  end

  test "on macOS, a launchd agent instead", ctx do
    {out, 0} = install(ctx, @base ++ ~w(--service launchd))
    plist = File.read!(Path.join(ctx.home, "Library/LaunchAgents/us.slipdock.runner.plist"))
    assert plist =~ "<string>#{ctx.home}/.local/bin/slipdock-runner</string>"
    assert plist =~ "<key>KeepAlive</key><true/>"
    assert out =~ "launchctl load -w"
  end

  test "with no service manager, says how to run it by hand", ctx do
    {out, 0} = install(ctx, @base ++ ~w(--service none))
    assert out =~ "nohup #{ctx.home}/.local/bin/slipdock-runner"
    refute File.exists?(Path.join(ctx.home, ".config/systemd"))
  end

  test "a custom command is kept exactly, quotes and all, and named by --kind", ctx do
    command = ~S{make agent PROMPT="$SLIPDOCK_PROMPT" && echo 'it''s done' `date`}

    {_, 0} =
      install(
        ctx,
        @base ++
          ["--agent", "custom", "--kind", "my-agent", "--command", command, "--service", "none"]
      )

    assert sourced(ctx, "CUSTOM_COMMAND") == command
    assert File.read!(Path.join(ctx.home, ".config/slipdock-runner/config")) =~ "job_my_agent() {"
  end

  test "a token or address with quotes in it can't break out of the config", ctx do
    {_, 0} =
      System.cmd(
        "sh",
        [
          ctx.script,
          "--url",
          "https://x.example",
          "--token",
          "sdr_a'; touch PWNED; '",
          "--no-start",
          "--service",
          "none"
        ],
        env: [{"HOME", ctx.home}],
        cd: ctx.home,
        stderr_to_stdout: true
      )

    assert sourced(ctx, "SLIPDOCK_RUNNER_TOKEN") == "sdr_a'; touch PWNED; '"
    refute File.exists?(Path.join(ctx.home, "PWNED"))
  end

  test "installing again keeps the old config beside the new one", ctx do
    {_, 0} = install(ctx, @base ++ ~w(--service none))

    {_, 0} =
      install(ctx, ~w(--url https://other.example --token sdr_new --no-start --service none))

    dir = Path.join(ctx.home, ".config/slipdock-runner")
    assert [backup] = Path.wildcard(Path.join(dir, "config.bak.*"))
    assert File.read!(backup) =~ "sdr_secret"
    assert sourced(ctx, "SLIPDOCK_RUNNER_TOKEN") == "sdr_new"
  end

  test "refuses what it can't use, before writing anything", ctx do
    for {args, message} <- [
          {~w(--token sdr_x), "--url is required"},
          {~w(--url https://x.example), "--token is required"},
          {~w(--url ftp://x --token t), "must start with http"},
          {~w(--url https://x --token t --pool Bad!), "--pool must be"},
          {~w(--url https://x --token t --agent vim), "--agent must be"},
          {~w(--url https://x --token t --agent custom), "needs --command"},
          {~w(--url https://x --token t --timeout soon), "--timeout must be"},
          {~w(--url https://x --token t --frobnicate), "unknown option"}
        ] do
      {out, 1} = install(ctx, args)
      assert out =~ message, "#{inspect(args)}: #{out}"
    end

    refute File.exists?(Path.join(ctx.home, ".local"))
  end
end
