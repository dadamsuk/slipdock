defmodule SlipdockWeb.CLIShellInstallTest do
  # `/cli/install.sh` (#2826), fetched from this app on a loopback port and
  # run for real under `sh` into a throwaway home, as `cli_powershell_test`
  # runs the Windows one. Its PATH is a folder of its own: links to the
  # ordinary tools it uses, and a stand-in `erl` and `escript` (or none), so
  # which Erlang this machine has doesn't matter and a missing one can be
  # tested. A fake `uname` says which system it is on.
  #
  # Sync: `Application.put_env(:slipdock, :cli_escript, …)` is global.
  use Slipdock.DataCase, async: false

  @sh System.find_executable("sh")
  @timeout System.find_executable("timeout")

  @tools ~w(cat chmod cp curl cut dirname head mkdir mktemp mv printf rm sed
            sha256sum shasum ssh-keygen tr perl)

  # This app, but answering one path with a body of the test's choosing: a
  # checksum that names other bytes, or a signature the release key never made.
  defmodule Answering do
    @behaviour Plug
    def init({path, body}), do: {path, body}

    def call(%{request_path: path} = conn, {path, body}), do: Plug.Conn.send_resp(conn, 200, body)
    def call(conn, _), do: SlipdockWeb.Endpoint.call(conn, SlipdockWeb.Endpoint.init([]))
  end

  @wrong_sums {Answering,
               {"/cli/SHA256SUMS", String.duplicate("0", 64) <> "  slipdock.escript\n"}}
  @bad_signature {Answering,
                  {"/cli/slipdock.escript.sig",
                   "-----BEGIN SSH SIGNATURE-----\nU1NIU0lH\n-----END SSH SIGNATURE-----\n"}}

  setup do
    dir = Path.join(System.tmp_dir!(), "slipdock-cli-sh-#{System.unique_integer([:positive])}")
    home = Path.join(dir, "home")
    File.mkdir_p!(home)

    built = Path.join(dir, "built.escript")
    bytes = "#!/usr/bin/env escript\n" <> Base.encode64(:crypto.strong_rand_bytes(3000)) <> "\n"
    File.write!(built, bytes)

    previous = Application.get_env(:slipdock, :cli_escript)
    Application.put_env(:slipdock, :cli_escript, built)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:slipdock, :cli_escript, previous),
        else: Application.delete_env(:slipdock, :cli_escript)

      File.rm_rf!(dir)
    end)

    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for tool <- @tools, path = System.find_executable(tool) do
      File.ln_s!(path, Path.join(bin, tool))
    end

    ctx = %{dir: dir, home: home, bin: bin, bytes: bytes, built: built}
    stub(ctx, "uname", "echo Linux")
    erlang(ctx, "27")

    Map.put(ctx, :url, serve(SlipdockWeb.Endpoint))
  end

  defp serve(plug) do
    {:ok, server} =
      Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    "http://127.0.0.1:#{port}"
  end

  defp stub(ctx, name, body) do
    path = Path.join(ctx.bin, name)
    File.rm(path)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
  end

  # A stand-in Erlang that says it is `otp`; nil takes Erlang away.
  defp erlang(ctx, nil) do
    File.rm(Path.join(ctx.bin, "erl"))
    File.rm(Path.join(ctx.bin, "escript"))
  end

  defp erlang(ctx, otp) do
    stub(ctx, "erl", "printf #{otp}")
    stub(ctx, "escript", "exit 0")
  end

  defp fetch(url) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {~c"#{url}/cli/install.sh", []}, [], body_format: :binary)

    body
  end

  defp dest(ctx), do: Path.join([ctx.home, ".local", "bin", "slipdock"])
  defp url_file(ctx), do: Path.join([ctx.home, ".config", "slipdock", "url"])

  # Fetched from `url` as a person would, then run under sh with `args`.
  defp install(ctx, args \\ [], url \\ nil) do
    script = Path.join(ctx.dir, "install-#{System.unique_integer([:positive])}.sh")
    File.write!(script, fetch(url || ctx.url))

    cmd = [@sh, script | args]
    # A deadline inside ExUnit's 60 s, where there is a `timeout` to give one.
    {exe, argv} = if @timeout, do: {@timeout, ["-k", "5", "40" | cmd]}, else: {@sh, tl(cmd)}

    System.cmd(exe, argv,
      env: [{"HOME", ctx.home}, {"PATH", ctx.bin}],
      stderr_to_stdout: true
    )
  end

  test "installs the CLI the server built, executable, and the server's address", ctx do
    {out, 0} = install(ctx)

    assert out =~ "slipdock: installed #{dest(ctx)}"
    assert out =~ "slipdock auth"
    assert File.read!(dest(ctx)) == ctx.bytes
    assert Bitwise.band(File.stat!(dest(ctx)).mode, 0o777) == 0o755
    assert File.read!(url_file(ctx)) == ctx.url <> "\n"
    assert Bitwise.band(File.stat!(url_file(ctx)).mode, 0o777) == 0o600
    # Nothing left beside it but the CLI.
    assert File.ls!(Path.dirname(dest(ctx))) == ["slipdock"]
  end

  test "says when the folder it installed into is not on the PATH", ctx do
    {out, 0} = install(ctx)
    assert out =~ "#{Path.dirname(dest(ctx))} is not on your PATH"
  end

  test "installs where $1 says", ctx do
    there = Path.join([ctx.dir, "elsewhere", "sd"])
    {_, 0} = install(ctx, [there])

    assert File.read!(there) == ctx.bytes
    refute File.exists?(dest(ctx))
  end

  test "running it again fetches the CLI afresh", ctx do
    {_, 0} = install(ctx)

    newer = "#!/usr/bin/env escript\n%% newer\n"
    File.write!(ctx.built, newer)
    {_, 0} = install(ctx)

    assert File.read!(dest(ctx)) == newer
  end

  test "a url naming another server is left alone, with a warning", ctx do
    File.mkdir_p!(Path.dirname(url_file(ctx)))
    File.write!(url_file(ctx), "https://other.example\n")

    {out, 0} = install(ctx)

    assert out =~ "already names https://other.example"
    assert File.read!(url_file(ctx)) == "https://other.example\n"
  end

  test "bytes that don't match the published checksum are refused, and nothing installed",
       ctx do
    {out, code} = install(ctx, [], serve(@wrong_sums))

    assert code != 0
    assert out =~ "does not match its published checksum"
    assert out =~ "nothing was installed"
    refute File.exists?(dest(ctx))
    refute File.exists?(url_file(ctx))
  end

  test "an existing CLI is kept when the new one doesn't match", ctx do
    {_, 0} = install(ctx)
    {_, code} = install(ctx, [], serve(@wrong_sums))

    assert code != 0
    assert File.read!(dest(ctx)) == ctx.bytes
  end

  test "a signature the release key didn't make is refused, and nothing installed", ctx do
    if System.find_executable("ssh-keygen") do
      {out, code} = install(ctx, [], serve(@bad_signature))

      assert code != 0
      assert out =~ "REFUSED"
      assert out =~ "nothing was installed"
      refute File.exists?(dest(ctx))
    end
  end

  test "a server built without the CLI installs nothing", ctx do
    File.rm!(ctx.built)
    {out, code} = install(ctx)

    assert code != 0
    assert out =~ "a server built without the slipdock CLI answers 404"
    refute File.exists?(dest(ctx))
    refute File.exists?(url_file(ctx))
  end

  describe "with no Erlang" do
    setup ctx do
      erlang(ctx, nil)
      :ok
    end

    test "on macOS it says brew install erlang, and writes nothing", ctx do
      stub(ctx, "uname", "echo Darwin")
      {out, code} = install(ctx)

      assert code == 1
      assert out =~ "Erlang/OTP 27 or later is needed and was not found; nothing was installed"
      assert out =~ "brew install erlang"
      assert File.ls!(ctx.home) == []
    end

    test "on Linux it names a package to install itself, and runs nothing as root", ctx do
      {out, code} = install(ctx)

      assert code == 1
      assert out =~ "Erlang/OTP 27 or later is needed and was not found"
      assert out =~ ~r/sudo (apt-get|dnf|pacman|apk|zypper) |your distribution's erlang package/
      assert out =~ "erlang.org/downloads"
      assert File.ls!(ctx.home) == []
    end
  end

  test "an Erlang older than 27 is refused before anything is written", ctx do
    erlang(ctx, "26")
    {out, code} = install(ctx)

    assert code == 1
    assert out =~ "is Erlang/OTP 26; the CLI needs 27 or later"
    assert File.ls!(ctx.home) == []
  end

  test "the script itself is POSIX sh, with no bashisms dash would trip on" do
    script = File.read!("priv/cli/install.sh")
    refute script =~ "[["
    refute script =~ ~r/^\s*function /m
    refute script =~ "local "
  end
end
