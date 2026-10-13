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
  use Slipdock.DataCase, async: false

  @pwsh System.get_env("SLIPDOCK_PWSH") || System.find_executable("pwsh")
  @escript System.find_executable("escript")

  if is_nil(@pwsh) do
    @moduletag skip: "pwsh (PowerShell) is not installed here; CI runs these"
  end

  # This app, but with a checksum that names other bytes.
  defmodule WrongSums do
    @behaviour Plug
    def init(opts), do: opts

    def call(%{request_path: "/cli/SHA256SUMS"} = conn, _opts),
      do: Plug.Conn.send_resp(conn, 200, String.duplicate("0", 64) <> "  slipdock.escript\n")

    def call(conn, _opts), do: SlipdockWeb.Endpoint.call(conn, SlipdockWeb.Endpoint.init([]))
  end

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

    %{dir: dir, home: home, bytes: bytes, built: escript, url: serve(SlipdockWeb.Endpoint)}
  end

  defp serve(plug) do
    {:ok, server} =
      Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    "http://127.0.0.1:#{port}"
  end

  defp fetch(url) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {~c"#{url}/cli/install.ps1", []}, [], body_format: :binary)

    body
  end

  defp inst(ctx), do: Path.join(ctx.dir, "inst")

  # Fetched from `url` as a person would, then run with `args`.
  defp install(ctx, args, url \\ nil) do
    script = Path.join(ctx.dir, "install-#{System.unique_integer([:positive])}.ps1")
    File.write!(script, fetch(url || ctx.url))

    {out, code} =
      System.cmd(
        @pwsh,
        ["-NoProfile", "-NonInteractive", "-File", script, "-Dir", inst(ctx), "-NoPath" | args],
        env: [{"HOME", ctx.home}, {"LOCALAPPDATA", nil}],
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
    {out, code} = install(ctx, ["-Escript", @escript], serve(WrongSums))

    assert code != 0
    assert out =~ "does not match its published checksum"
    assert out =~ "nothing was installed"
    refute File.exists?(Path.join(inst(ctx), "slipdock.escript"))
    refute File.exists?(Path.join(inst(ctx), "slipdock.cmd"))
    assert Path.wildcard(Path.join(inst(ctx), "*.part")) == []
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
    # An Erlang where Windows would have one: escript.exe on the PATH, erl.exe beside it.
    bin = Path.join(ctx.dir, "erlang-bin")
    File.mkdir_p!(bin)

    for {name, body} <- [{"escript.exe", "#!/bin/sh\n"}, {"erl.exe", "#!/bin/sh\nprintf 27\n"}] do
      File.write!(Path.join(bin, name), body)
      File.chmod!(Path.join(bin, name), 0o755)
    end

    command = """
    $ErrorActionPreference = 'Continue'; $ProgressPreference = 'Continue'
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
