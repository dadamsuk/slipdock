defmodule SlipdockWeb.CLIPowerShellTest do
  # `/cli/install.ps1`, fetched from this app on a loopback port and run for
  # real under `pwsh` into a throwaway home — when PowerShell is installed.
  # GitHub's Ubuntu runners have it; a machine without it skips these with
  # the reason. `SLIPDOCK_PWSH` names another one.
  #
  # The Windows-only parts (the user PATH in the registry, winget) can't run
  # here: -NoPath stands in for the first, and -Escript names this machine's
  # Erlang so the second is never reached, except where the test is that it
  # is refused.
  #
  # The CLI the server serves is signed with a key the test makes, written
  # into the installer in place of the release key, as a release is signed
  # (#3506: without a signature it checks, it installs nothing unless told to).
  use Slipdock.DataCase, async: false

  @pwsh System.get_env("SLIPDOCK_PWSH") || System.find_executable("pwsh")
  @escript System.find_executable("escript")

  if is_nil(@pwsh) do
    @moduletag skip: "pwsh (PowerShell) is not installed here; CI runs these"
  end

  alias SlipdockWeb.CLIInstallSigning, as: Signing

  @wrong_sums Signing.wrong_sums()
  @bad_signature Signing.bad_signature()

  setup do
    dir = Path.join(System.tmp_dir!(), "slipdock-cli-ps-#{System.unique_integer([:positive])}")
    home = Path.join(dir, "home")
    File.mkdir_p!(home)

    escript = Path.join(dir, "built.escript")
    bytes = "#!/usr/bin/env escript\n" <> Base.encode64(:crypto.strong_rand_bytes(3000)) <> "\n"
    File.write!(escript, bytes)

    previous = Application.get_env(:slipdock, :cli_escript)
    Application.put_env(:slipdock, :cli_escript, escript)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:slipdock, :cli_escript, previous),
        else: Application.delete_env(:slipdock, :cli_escript)

      File.rm_rf!(dir)
    end)

    ctx = %{dir: dir, home: home, bytes: bytes, built: escript, url: serve(SlipdockWeb.Endpoint)}
    ctx = Map.put(ctx, :public_key, release_key(ctx))
    sign(ctx)
    ctx
  end

  # A key of the test's own, standing in for the release key.
  defp release_key(ctx), do: Signing.new_key(Path.join(ctx.dir, "release_key"))

  # The CLI's bytes signed with `key` (the release key's stand-in by
  # default), the signature beside them, where the server serves it from.
  defp sign(ctx, key \\ "release_key"), do: Signing.sign(ctx.built, Path.join(ctx.dir, key))

  defp unsign(ctx), do: Signing.unsign(ctx.built)

  # The script as served, with `key` as its release key instead.
  defp with_release_key(key) do
    &String.replace(&1, ~r/^  \$ReleaseKey = '.*'$/m, "  $ReleaseKey = '#{key}'")
  end

  defp serve(plug) do
    # Under the test's supervisor (TEST-16), which stops it when the test
    # ends; the id lets a test start a second one beside setup's.
    server =
      start_supervised!(
        {Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {Bandit, plug}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp fetch(url) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {~c"#{url}/cli/install.ps1", []}, [], body_format: :binary)

    body
  end

  defp inst(ctx), do: Path.join(ctx.dir, "inst")

  # Fetched from `url` as a person would, then run with `args`. `opts`:
  # `:edit`, a function given the script as served (by default it swaps in
  # the test's key for the release key); `:env`, more of the environment.
  defp install(ctx, args, url \\ nil, opts \\ []) do
    script = Path.join(ctx.dir, "install-#{System.unique_integer([:positive])}.ps1")
    edit = Keyword.get(opts, :edit, with_release_key(ctx.public_key))
    File.write!(script, edit.(fetch(url || ctx.url)))

    {out, code} =
      System.cmd(
        @pwsh,
        ["-NoProfile", "-NonInteractive", "-File", script, "-Dir", inst(ctx), "-NoPath" | args],
        env:
          [{"HOME", ctx.home}, {"LOCALAPPDATA", nil}, {"SLIPDOCK_ALLOW_UNSIGNED", nil}] ++
            Keyword.get(opts, :env, []),
        stderr_to_stdout: true
      )

    {squash(out), code}
  end

  # PowerShell wraps an error to the console's width and colours it; read
  # back as one line of plain text.
  defp squash(out) do
    out
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.replace(~r/\s*\n\s*\|?\s*/, " ")
  end

  defp url_file(ctx), do: Path.join([ctx.home, ".config", "slipdock", "url"])

  test "installs the CLI the server built, a shim that runs it, and the server's address", ctx do
    {out, 0} = install(ctx, ["-Escript", @escript])

    assert out =~ "signature checked against the release key"
    assert out =~ "installed"
    assert out =~ "slipdock auth"
    assert File.read!(Path.join(inst(ctx), "slipdock.escript")) == ctx.bytes

    shim = File.read!(Path.join(inst(ctx), "slipdock.cmd"))
    assert shim =~ ~s("#{@escript}" "%~dp0slipdock.escript" %*\r\n)
    assert shim =~ ~s(set "PATH=#{Path.dirname(@escript)};%PATH%"\r\n)
    assert shim =~ "exit /b %ERRORLEVEL%"
    assert String.printable?(shim) and shim == for(<<c <- shim>>, c < 128, into: "", do: <<c>>)

    assert File.read!(url_file(ctx)) |> String.trim() == ctx.url
    assert File.ls!(inst(ctx)) |> Enum.sort() == ["slipdock.cmd", "slipdock.escript"]
  end

  test "running it again fetches the CLI afresh", ctx do
    {_, 0} = install(ctx, ["-Escript", @escript])

    newer = "#!/usr/bin/env escript\n%% newer\n"
    File.write!(ctx.built, newer)
    sign(ctx)
    {_, 0} = install(ctx, ["-Escript", @escript])

    assert File.read!(Path.join(inst(ctx), "slipdock.escript")) == newer
  end

  test "a url naming another server is left alone, with a warning", ctx do
    File.mkdir_p!(Path.dirname(url_file(ctx)))
    File.write!(url_file(ctx), "https://other.example\n")

    {out, 0} = install(ctx, ["-Escript", @escript])

    assert out =~ "already names https://other.example"
    assert File.read!(url_file(ctx)) == "https://other.example\n"
  end

  test "bytes that don't match the published checksum are not installed", ctx do
    {out, code} = install(ctx, ["-Escript", @escript], serve(@wrong_sums))

    assert code != 0
    assert out =~ "does not match its published checksum"
    assert out =~ "nothing was installed"
    nothing_installed(ctx)
  end

  defp nothing_installed(ctx) do
    refute File.exists?(Path.join(inst(ctx), "slipdock.escript"))
    refute File.exists?(Path.join(inst(ctx), "slipdock.cmd"))
    refute File.exists?(url_file(ctx))
    # Nothing left of the download either.
    assert Path.wildcard(Path.join(inst(ctx), "*"), match_dot: true) == []
  end

  test "a signature the release key didn't make is refused, and nothing installed", ctx do
    {out, code} = install(ctx, ["-Escript", @escript], serve(@bad_signature))

    assert code != 0
    assert out =~ ~r/REFUSED: the CLI from http:\S+ is not signed with the project's release key/
    assert out =~ "nothing was installed"
    nothing_installed(ctx)
  end

  test "a signature made by another key is refused, even with -AllowUnsigned", ctx do
    other = Path.join(ctx.dir, "other")
    Signing.new_key(other)
    sign(ctx, "other")

    {out, code} = install(ctx, ["-Escript", @escript, "-AllowUnsigned"])

    assert code != 0
    assert out =~ "is not signed with the project's release key"
    nothing_installed(ctx)
  end

  describe "a server that serves no signature, as one built from source" do
    setup ctx do
      unsign(ctx)
      :ok
    end

    test "is refused with the reason and how to allow it, and nothing installed", ctx do
      {out, code} = install(ctx, ["-Escript", @escript])

      assert code != 0

      assert out =~
               "REFUSED: #{ctx.url} serves no signature for the CLI (/cli/slipdock.escript.sig), " <>
                 "so it can't be checked against the release key; nothing was installed."

      assert out =~ "-AllowUnsigned"
      nothing_installed(ctx)
    end

    test "installs on the checksum with -AllowUnsigned, and says so", ctx do
      {out, 0} = install(ctx, ["-Escript", @escript, "-AllowUnsigned"])

      assert out =~ "installing it on the checksum alone, as -AllowUnsigned says"
      assert File.read!(Path.join(inst(ctx), "slipdock.escript")) == ctx.bytes
    end

    test "installs with SLIPDOCK_ALLOW_UNSIGNED=1, and not with 0", ctx do
      {out, code} =
        install(ctx, ["-Escript", @escript], nil, env: [{"SLIPDOCK_ALLOW_UNSIGNED", "0"}])

      assert code != 0
      assert out =~ "REFUSED"

      {out, 0} =
        install(ctx, ["-Escript", @escript], nil, env: [{"SLIPDOCK_ALLOW_UNSIGNED", "1"}])

      assert out =~ "installing it on the checksum alone"
      assert File.read!(Path.join(inst(ctx), "slipdock.escript")) == ctx.bytes
    end
  end

  test "with no release key in the installer it is refused, or installed with -AllowUnsigned",
       ctx do
    {out, code} = install(ctx, ["-Escript", @escript], nil, edit: with_release_key(""))

    assert code != 0
    assert out =~ "serves a signature but this installer has no release key"
    nothing_installed(ctx)

    {out, 0} =
      install(ctx, ["-Escript", @escript, "-AllowUnsigned"], nil, edit: with_release_key(""))

    assert out =~ "installing it on the checksum alone"
    assert File.read!(Path.join(inst(ctx), "slipdock.escript")) == ctx.bytes
  end

  describe "with no ssh-keygen here" do
    # A PATH of one folder holding links to everything on this one but
    # ssh-keygen (Erlang's own scripts still want the ordinary tools).
    setup ctx do
      bin = Path.join(ctx.dir, "no-keygen")
      File.mkdir_p!(bin)

      for dir <- System.get_env("PATH") |> String.split(":") |> Enum.uniq(),
          {:ok, names} <- [File.ls(dir)],
          name <- names,
          name != "ssh-keygen" do
        File.ln_s(Path.join(dir, name), Path.join(bin, name))
      end

      %{no_keygen: [{"PATH", bin}]}
    end

    test "it is refused, and nothing installed", ctx do
      {out, code} = install(ctx, ["-Escript", @escript], nil, env: ctx.no_keygen)

      assert code != 0
      assert out =~ "REFUSED: there is no ssh-keygen here to check the CLI's signature with"
      assert out =~ "-AllowUnsigned"
      nothing_installed(ctx)
    end

    test "it installs on the checksum with -AllowUnsigned", ctx do
      {out, 0} = install(ctx, ["-Escript", @escript, "-AllowUnsigned"], nil, env: ctx.no_keygen)

      assert out =~ "there is no ssh-keygen here"
      refute out =~ "signature checked"
      assert File.read!(Path.join(inst(ctx), "slipdock.escript")) == ctx.bytes
    end
  end

  test "a server built without the CLI installs nothing", ctx do
    File.rm!(ctx.built)
    {out, code} = install(ctx, ["-Escript", @escript])

    assert code != 0
    assert out =~ "this server was built without the slipdock CLI"
    refute File.exists?(Path.join(inst(ctx), "slipdock.escript"))
    refute File.exists?(url_file(ctx))
  end

  test "with no Erlang and -NoErlang it stops and says where to get it", ctx do
    {out, code} = install(ctx, ["-NoErlang"])

    assert code != 0
    assert out =~ "Erlang/OTP 27 or later is needed"
    assert out =~ "erlang.org/downloads"
    refute File.exists?(inst(ctx))
  end

  test "with no Erlang and no winget it says so rather than failing somewhere odd", ctx do
    {out, code} = install(ctx, [])

    assert code != 0
    assert out =~ "winget is not here"
  end

  test "an Erlang older than 27 is refused before anything is written", ctx do
    bin = Path.join(ctx.dir, "old-erlang")
    File.mkdir_p!(bin)
    old_escript = Path.join(bin, "escript")
    File.write!(old_escript, "#!/bin/sh\n")
    File.write!(Path.join(bin, "erl"), "#!/bin/sh\nprintf 26\n")
    File.chmod!(Path.join(bin, "erl"), 0o755)

    {out, code} = install(ctx, ["-Escript", old_escript])

    assert code != 0
    assert out =~ "Erlang/OTP 26; the CLI needs 27 or later"
    refute File.exists?(inst(ctx))
  end

  test "-Uninstall takes the folder away and keeps the sign-in", ctx do
    {_, 0} = install(ctx, ["-Escript", @escript])
    assert File.exists?(url_file(ctx))

    {out, 0} = install(ctx, ["-Uninstall"])

    assert out =~ "removed"
    refute File.exists?(inst(ctx))
    assert File.exists?(url_file(ctx))
  end

  test "`irm | iex` installs, and leaves the person's session as it was", ctx do
    bin = windows_erlang(ctx)

    # `irm | iex` runs the script as served, with the real release key in
    # it, so the server here serves no signature and the person allows that.
    unsign(ctx)

    command = """
    $ErrorActionPreference = 'Continue'; $ProgressPreference = 'Continue'
    $env:SLIPDOCK_ALLOW_UNSIGNED = '1'
    irm '#{ctx.url}/cli/install.ps1' | iex
    "session: $ErrorActionPreference $ProgressPreference $(Test-Path function:Find-Escript)"
    """

    {out, code} =
      System.cmd(@pwsh, ["-NoProfile", "-NonInteractive", "-Command", command],
        env: [
          {"HOME", ctx.home},
          {"LOCALAPPDATA", ctx.dir},
          {"PATH", bin <> ":" <> System.get_env("PATH")}
        ],
        stderr_to_stdout: true
      )

    assert code == 0, out
    assert out =~ "session: Continue Continue False"

    installed = Path.join([ctx.dir, "Programs", "slipdock"])
    assert File.read!(Path.join(installed, "slipdock.escript")) == ctx.bytes
    assert File.read!(Path.join(installed, "slipdock.cmd")) =~ Path.join(bin, "escript.exe")
  end

  # An Erlang where Windows would have one: escript.exe on the PATH, erl.exe beside it.
  defp windows_erlang(ctx) do
    bin = Path.join(ctx.dir, "erlang-bin")
    File.mkdir_p!(bin)

    for {name, body} <- [{"escript.exe", "#!/bin/sh\n"}, {"erl.exe", "#!/bin/sh\nprintf 27\n"}] do
      File.write!(Path.join(bin, name), body)
      File.chmod!(Path.join(bin, name), 0o755)
    end

    bin
  end

  test "`irm | iex` of an unsigned CLI stops there unless allowed", ctx do
    unsign(ctx)
    command = "irm '#{ctx.url}/cli/install.ps1' | iex"

    {out, code} =
      System.cmd(@pwsh, ["-NoProfile", "-NonInteractive", "-Command", command],
        env: [
          {"HOME", ctx.home},
          {"LOCALAPPDATA", ctx.dir},
          {"SLIPDOCK_ALLOW_UNSIGNED", nil},
          {"PATH", windows_erlang(ctx) <> ":" <> System.get_env("PATH")}
        ],
        stderr_to_stdout: true
      )

    assert code != 0
    assert squash(out) =~ "serves no signature for the CLI"
    refute File.exists?(Path.join([ctx.dir, "Programs", "slipdock", "slipdock.escript"]))
    refute File.exists?(url_file(ctx))
  end

  test "`irm | iex` with no Erlang and no winget stops there", ctx do
    command = "irm '#{ctx.url}/cli/install.ps1' | iex"

    {out, code} =
      System.cmd(@pwsh, ["-NoProfile", "-NonInteractive", "-Command", command],
        env: [{"HOME", ctx.home}, {"LOCALAPPDATA", nil}],
        stderr_to_stdout: true
      )

    assert code != 0
    assert squash(out) =~ "winget is not here"
    refute File.exists?(url_file(ctx))
  end
end
