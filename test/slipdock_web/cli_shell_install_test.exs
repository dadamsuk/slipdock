defmodule SlipdockWeb.CLIShellInstallTest do
  # `/cli/install.sh` (#2826), fetched from this app on a loopback port and
  # run for real under `sh` into a throwaway home, as `cli_powershell_test`
  # runs the Windows one. Its PATH is a folder of its own: links to the
  # ordinary tools it uses, and a stand-in `erl` and `escript` (or none), so
  # which Erlang this machine has doesn't matter and a missing one can be
  # tested. A fake `uname` says which system it is on. The CLI the server
  # serves is signed with a key the test makes, written into the installer
  # in place of the release key, as a release is signed (#3506: without a
  # signature it checks, it installs nothing unless told to).
  #
  # Sync: `Application.put_env(:slipdock, :cli_escript, …)` is global.
  use Slipdock.DataCase, async: false

  @sh System.find_executable("sh")
  @timeout System.find_executable("timeout")

  @tools ~w(cat chmod cp curl cut dirname head mkdir mktemp mv printf rm sed
            sha256sum shasum ssh-keygen tr perl)

  alias SlipdockWeb.CLIInstallSigning, as: Signing
  alias SlipdockWeb.CLIInstallSigning.Answering

  @wrong_sums Signing.wrong_sums()
  @bad_signature Signing.bad_signature()

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

    ctx
    |> Map.put(:url, serve(SlipdockWeb.Endpoint))
    |> Map.put(:public_key, release_key(ctx))
    |> tap(&sign/1)
  end

  # A key of the test's own, standing in for the release key.
  defp release_key(ctx), do: Signing.new_key(Path.join(ctx.dir, "release_key"))

  # The CLI's bytes signed with `key` (the release key's stand-in by
  # default), the signature beside them, where the server serves it from.
  defp sign(ctx, key \\ "release_key"), do: Signing.sign(ctx.built, Path.join(ctx.dir, key))

  defp unsign(ctx), do: Signing.unsign(ctx.built)

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
  # `opts`: `:edit`, a function given the script as served (by default it
  # swaps in the test's key for the release key); `:env`, more of the
  # environment; `:path`, the PATH (the test's own bin folder by default).
  defp install(ctx, args \\ [], url \\ nil, opts \\ []) do
    script = Path.join(ctx.dir, "install-#{System.unique_integer([:positive])}.sh")
    edit = Keyword.get(opts, :edit, with_release_key(ctx.public_key))
    File.write!(script, edit.(fetch(url || ctx.url)))

    cmd = [@sh, script | args]
    # A deadline inside ExUnit's 60 s, where there is a `timeout` to give one.
    {exe, argv} = if @timeout, do: {@timeout, ["-k", "5", "40" | cmd]}, else: {@sh, tl(cmd)}

    System.cmd(exe, argv,
      env:
        [{"HOME", ctx.home}, {"PATH", Keyword.get(opts, :path, ctx.bin)}] ++
          Keyword.get(opts, :env, []),
      stderr_to_stdout: true
    )
  end

  test "installs the CLI the server built, executable, and the server's address", ctx do
    {out, 0} = install(ctx)

    assert out =~ "signature checked against the release key"
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
    sign(ctx)
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
    {out, code} = install(ctx, [], serve(@bad_signature))

    assert code == 1
    assert out =~ ~r/REFUSED: the CLI from http:\S+ is not signed with the project.s release key/
    assert out =~ "nothing was installed"
    nothing_installed(ctx)
  end

  test "a signature the release key didn't make is refused even with --allow-unsigned", ctx do
    {out, code} = install(ctx, ["--allow-unsigned"], serve(@bad_signature))

    assert code == 1
    assert out =~ "is not signed with the project's release key"
    nothing_installed(ctx)
  end

  test "a signature made by another key is refused", ctx do
    Signing.new_key(Path.join(ctx.dir, "other"))
    sign(ctx, "other")

    {out, 1} = install(ctx)

    assert out =~ "is not signed with the project's release key"
    nothing_installed(ctx)
  end

  describe "a server that serves no signature, as one built from source" do
    setup ctx do
      unsign(ctx)
      :ok
    end

    test "is refused with the reason and how to allow it, and nothing installed", ctx do
      {out, code} = install(ctx)

      assert code == 1

      assert out =~
               "REFUSED: #{ctx.url} serves no signature for the CLI (/cli/slipdock.escript.sig), " <>
                 "so it can't be checked against the release key; nothing was installed."

      assert out =~ "curl -fsSL #{ctx.url}/cli/install.sh | sh -s -- --allow-unsigned"
      nothing_installed(ctx)
    end

    test "installs on the checksum with --allow-unsigned, and says so", ctx do
      {out, 0} = install(ctx, ["--allow-unsigned"])

      assert out =~ "warning: #{ctx.url} serves no signature for the CLI"
      assert out =~ "installing it on the checksum alone, as --allow-unsigned says"
      assert File.read!(dest(ctx)) == ctx.bytes
    end

    test "--allow-unsigned goes with a path of its own", ctx do
      there = Path.join([ctx.dir, "elsewhere", "sd"])
      {_, 0} = install(ctx, ["--allow-unsigned", there])

      assert File.read!(there) == ctx.bytes
      refute File.exists?(dest(ctx))
    end

    test "installs with SLIPDOCK_ALLOW_UNSIGNED=1", ctx do
      {out, 0} = install(ctx, [], nil, env: [{"SLIPDOCK_ALLOW_UNSIGNED", "1"}])

      assert out =~ "installing it on the checksum alone"
      assert File.read!(dest(ctx)) == ctx.bytes
    end

    test "is still refused with SLIPDOCK_ALLOW_UNSIGNED set to anything but 1", ctx do
      for value <- ["0", "", "yes"] do
        {out, 1} = install(ctx, [], nil, env: [{"SLIPDOCK_ALLOW_UNSIGNED", value}])
        assert out =~ "REFUSED"
        nothing_installed(ctx)
      end
    end

    test "a bad checksum is refused even with --allow-unsigned", ctx do
      {out, 1} = install(ctx, ["--allow-unsigned"], serve(@wrong_sums))

      assert out =~ "does not match its published checksum"
      nothing_installed(ctx)
    end
  end

  test "an option it doesn't know is refused, and nothing installed", ctx do
    {out, 1} = install(ctx, ["--allow-unsigend"])

    assert out =~ "unknown option --allow-unsigend"
    nothing_installed(ctx)
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

  # The script as served, with `key` as its release key instead.
  defp with_release_key(key) do
    &String.replace(&1, ~r/^RELEASE_KEY='.*'$/m, "RELEASE_KEY='#{key}'")
  end

  defp unlink(ctx, tool), do: File.rm(Path.join(ctx.bin, tool))

  defp nothing_installed(ctx) do
    refute File.exists?(dest(ctx))
    refute File.exists?(url_file(ctx))
  end

  test "says nothing of the PATH when the folder it installed into is on it", ctx do
    {out, 0} = install(ctx, [], nil, path: ctx.bin <> ":" <> Path.dirname(dest(ctx)))

    assert out =~ "slipdock: installed #{dest(ctx)}"
    refute out =~ "is not on your PATH"
  end

  test "a SHA256SUMS that doesn't name slipdock.escript is refused, and nothing installed",
       ctx do
    sums = String.duplicate("a", 64) <> "  something-else.escript\n"
    {out, code} = install(ctx, [], serve({Answering, {"/cli/SHA256SUMS", sums}}))

    assert code == 1
    assert out =~ "/cli/SHA256SUMS has no checksum for slipdock.escript; nothing was installed"
    nothing_installed(ctx)
  end

  test "an Erlang it can't read the version of is warned about, and the CLI installed", ctx do
    erlang(ctx, "not-a-number")
    {out, 0} = install(ctx)

    assert out =~ "warning: couldn't tell which Erlang/OTP"
    assert out =~ "the CLI needs 27 or later"
    assert File.read!(dest(ctx)) == ctx.bytes
  end

  describe "without curl" do
    setup ctx do
      unlink(ctx, "curl")
      :ok
    end

    test "it fetches with wget", ctx do
      # A wget that takes only the arguments the script gives it, and
      # fetches with curl from outside the PATH folder.
      curl = System.find_executable("curl")

      stub(ctx, "wget", """
      [ "$1" = -q ] && [ "$2" = -O ] && [ $# -eq 4 ] || { echo "wget: unexpected $*" >&2; exit 2; }
      exec #{curl} -fsS -o "$3" "$4"
      """)

      {out, 0} = install(ctx)

      assert out =~ "slipdock: installed #{dest(ctx)}"
      assert File.read!(dest(ctx)) == ctx.bytes
    end

    test "or with no wget either, says it needs one, and installs nothing", ctx do
      {out, code} = install(ctx)

      assert code == 1
      assert out =~ "slipdock: needs curl or wget"
      assert File.ls!(ctx.home) == []
    end
  end

  test "with no sha256sum, as on an older macOS, it checks with shasum -a 256", ctx do
    unlink(ctx, "sha256sum")

    unless System.find_executable("shasum") do
      # No shasum here: one that answers only for -a 256.
      sha256sum = System.find_executable("sha256sum")
      stub(ctx, "shasum", ~s([ "$1 $2" = "-a 256" ] || exit 2\nexec #{sha256sum} "$3"))
    end

    {out, 0} = install(ctx)

    assert out =~ "slipdock: installed #{dest(ctx)}"
    assert File.read!(dest(ctx)) == ctx.bytes
  end

  describe "a signed release" do
    test "with no release key in the installer is refused, and nothing installed", ctx do
      {out, code} = install(ctx, [], nil, edit: with_release_key(""))

      assert code == 1
      assert out =~ "REFUSED: #{ctx.url} serves a signature but this installer has no release key"
      assert out =~ "nothing was installed"
      assert out =~ "--allow-unsigned"
      nothing_installed(ctx)
    end

    test "with no release key in the installer installs with --allow-unsigned", ctx do
      {out, 0} = install(ctx, ["--allow-unsigned"], nil, edit: with_release_key(""))

      assert out =~ "warning: #{ctx.url} serves a signature but this installer has no release key"
      assert File.read!(dest(ctx)) == ctx.bytes
    end

    test "with no ssh-keygen here is refused, and nothing installed", ctx do
      unlink(ctx, "ssh-keygen")
      {out, code} = install(ctx)

      assert code == 1
      assert out =~ "REFUSED: there is no ssh-keygen here to check the CLI's signature with"
      assert out =~ "--allow-unsigned"
      nothing_installed(ctx)
    end

    test "with no ssh-keygen here installs on the checksum with --allow-unsigned", ctx do
      unlink(ctx, "ssh-keygen")
      {out, 0} = install(ctx, ["--allow-unsigned"])

      assert out =~ "warning: there is no ssh-keygen here"
      refute out =~ "signature checked"
      assert File.read!(dest(ctx)) == ctx.bytes
    end
  end

  describe "with no Erlang, on Linux, it names the distribution's package" do
    setup ctx do
      erlang(ctx, nil)
      :ok
    end

    for {name, os_release, line} <- [
          {"debian", "ID=debian\n", "sudo apt-get install erlang-nox"},
          {"ubuntu", "ID=ubuntu\nID_LIKE=debian\n", "sudo apt-get install erlang-nox"},
          {"fedora", ~s(ID="fedora"\n), "sudo dnf install erlang"},
          {"rocky", ~s(ID="rocky"\nID_LIKE="rhel centos fedora"\n), "sudo dnf install erlang"},
          {"arch", "ID=arch\n", "sudo pacman -S erlang"},
          {"alpine", "ID=alpine\n", "sudo apk add erlang"},
          {"opensuse", ~s(ID="opensuse-leap"\nID_LIKE="suse opensuse"\n),
           "sudo zypper install erlang"},
          {"an unknown one", "ID=plan9\n", "your distribution's erlang package"}
        ] do
      test "#{name}", ctx do
        file = Path.join(ctx.dir, "os-release")
        File.write!(file, unquote(os_release))

        {out, 1} = install(ctx, [], nil, env: [{"SLIPDOCK_OS_RELEASE", file}])

        assert out =~ "\n  #{unquote(line)}\n"
        # Only the one it names.
        assert length(Regex.scan(~r/^  (sudo |your distribution)/m, out)) == 1
        assert File.ls!(ctx.home) == []
      end
    end
  end

  test "the script itself is POSIX sh, with no bashisms dash would trip on" do
    script = File.read!("priv/cli/install.sh")
    refute script =~ "[["
    refute script =~ ~r/^\s*function /m
    refute script =~ "local "
  end
end
