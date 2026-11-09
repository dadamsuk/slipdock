defmodule Slipdock.DaemonJobLogE2ETest do
  @moduledoc """
  `tools/e2e/daemon-job-log.sh` and its `.mjs` (#2628) run a real job
  through the runner daemon and watch the card's live log in Chromium. CI
  can't run them (they need a signed-in `claude`), so this holds them to
  what they drive, where a change elsewhere would leave them broken
  unseen: every element the browser half reads is one the job log
  component renders; every flag given to `slipdock-runner` is one the
  daemon defines; every `local.json` key it writes is one the daemon reads
  (a renamed `no_skills_update` would let the throwaway server's skills
  into `~/.claude/skills`); every runner config field is one the server
  takes; and the daemon is kept in a scratch directory of its own.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.BoardLive.JobLogComponent

  @root Path.expand("../..", __DIR__)
  @files %{
    sh: "tools/e2e/daemon-job-log.sh",
    mjs: "tools/e2e/daemon-job-log.mjs",
    component: "lib/slipdock_web/live/board_live/job_log_component.ex",
    init: "daemon/internal/cli/init.go",
    run: "daemon/internal/cli/run.go",
    cli: "daemon/internal/cli/cli.go",
    local: "daemon/internal/machine/local.go",
    machines: "lib/slipdock/machines.ex",
    runners: "lib/slipdock/runners.ex",
    deployments: "lib/slipdock/deployments.ex",
    oauth: "lib/slipdock/oauth/client.ex"
  }
  for {_, path} <- @files, do: @external_resource(Path.join(@root, path))

  defp read(which), do: File.read!(Path.join(@root, Map.fetch!(@files, which)))

  # The flags a Go file defines with fs.String/Bool/Int/Var.
  defp go_flags(which) do
    ~r/fs\.(?:String|Bool|Int|Var)\((?:&\w+, )?"([a-z-]+)"/
    |> Regex.scan(read(which), capture: :all_but_first)
    |> List.flatten()
  end

  # The flags the script gives `"$DAEMON" <command>`, up to its redirect.
  defp script_flags(command) do
    [args] =
      Regex.run(~r/"\$DAEMON" #{command} ([^>]*)>/s, read(:sh), capture: :all_but_first)

    ~r/(?<![\w-])--([a-z-]+)/ |> Regex.scan(args, capture: :all_but_first) |> List.flatten()
  end

  test "the browser half reads only elements the job log component renders" do
    assert JobLogComponent.id("card", 7) == "job-log-card-7"
    assert read(:mjs) =~ "const log = `#job-log-card-${job}`"

    suffixes =
      ~r/\$\{log\}-([a-z]+)/
      |> Regex.scan(read(:mjs), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert Enum.sort(suffixes) == ~w(expires keep kept lines toggle)

    for suffix <- suffixes do
      assert read(:component) =~ ~s|id={"\#{@id}-#{suffix}"}|,
             "the job log component renders no #{suffix} element"
    end
  end

  test "the flags given to slipdock-runner are ones the daemon defines" do
    init = script_flags("init")
    run = script_flags("run")

    assert "home" in init and "home" in run,
           "the daemon must run from --home, never the machine's own"

    assert "key" in init and "as-me" in init and "no-setup" in init

    for flag <- init,
        do: assert(flag in (go_flags(:init) ++ go_flags(:cli)), "init has no --#{flag}")

    for flag <- run,
        do: assert(flag in (go_flags(:run) ++ go_flags(:cli)), "run has no --#{flag}")
  end

  test "the local.json keys it writes are ones the daemon reads, and the skills stay put" do
    sh = read(:sh)
    local = read(:local)

    for key <- ~w(agents path allowed_tools no_skills_update) do
      assert sh =~ ~s("#{key}"), "the script no longer writes #{key}"
      assert local =~ ~s(json:"#{key}), "local.json has no #{key} field"
    end

    assert sh =~ ~s|local["no_skills_update"] = True|
  end

  test "the runner it adds uses only config fields the server takes, with the job run as this account" do
    [config] =
      Regex.run(~r/"config" => %\{(.*?)\n\s*\}/s, read(:sh), capture: :all_but_first)

    keys = ~r/"(\w+)" =>/ |> Regex.scan(config, capture: :all_but_first) |> List.flatten()
    fields = Enum.map(Slipdock.Runners.Config.fields(), &Atom.to_string/1)

    assert keys != []
    for key <- keys, do: assert(key in fields, "runner config has no #{key}")
    assert config =~ ~s("executor" => "me")
    assert config =~ ~s("permission_mode" => "acceptEdits")
  end

  test "the server's transcript is checked for both keys and every token shape the server mints" do
    sh = read(:sh)
    assert sh =~ ~S|if String.contains?(raw, "'"$MACHINE_KEY"'"), do: raise(|
    assert sh =~ ~S|if String.contains?(raw, "'"$KEY"'"), do: raise(|
    assert sh =~ ~S|read -r CARD KEY <<<|
    assert sh =~ "no machine key or token"

    [source] = Regex.run(~r/if raw =~ ~r\/(.+?)\/, do: raise/, sh, capture: :all_but_first)
    shape = Regex.compile!(source)

    prefixes =
      ~r/"(sd[a-z]_)" <>|@\w+_prefix "(sd[a-z]_)"/
      |> Regex.scan(Enum.map_join(~w(machines runners deployments oauth)a, &read/1),
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    assert Enum.sort(prefixes) == ~w(sdc_ sdd_ sde_ sdm_ sdr_)

    for prefix <- prefixes, bytes <- [18, 32] do
      token = prefix <> Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)
      assert Regex.match?(shape, "Bearer " <> token), "the token check misses #{prefix}"
    end

    refute Regex.match?(shape, "the sdm_ prefix and slipdock-runner")
  end

  test "the scratch daemon is stopped before the server goes" do
    sh = read(:sh)
    assert sh =~ ~r/trap 'kill \$RUNNER .*kill \$E2E_SERVER/
    assert sh =~ ~S|source "$(dirname "$0")/lib.sh"|
  end
end
