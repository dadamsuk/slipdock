defmodule SlipdockWeb.CLIInstallControllerTest do
  # `/cli/*`: the Windows installer names the server it came from, and the
  # escript and its checksum are served when the image built one and refused
  # plainly when it did not. The installer run for real is in
  # `SlipdockWeb.CLIPowerShellTest`.
  use SlipdockWeb.ConnCase, async: false

  @moduletag :anonymous

  setup do
    dir = Path.join(System.tmp_dir!(), "slipdock-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    escript = Path.join(dir, "slipdock.escript")
    previous = Application.get_env(:slipdock, :cli_escript)
    Application.put_env(:slipdock, :cli_escript, escript)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:slipdock, :cli_escript, previous),
        else: Application.delete_env(:slipdock, :cli_escript)

      File.rm_rf!(dir)
    end)

    %{escript: escript}
  end

  describe "GET /cli/install.ps1" do
    test "is plain text that installs from this server", %{conn: conn} do
      conn = conn |> Map.put(:host, "boards.example") |> get("/cli/install.ps1")
      body = response(conn, 200)

      assert response_content_type(conn, :text) =~ "text/plain"
      assert body =~ "$Base = 'http://boards.example'"
      assert body =~ "irm http://boards.example/cli/install.ps1 | iex"
      refute body =~ "__SLIPDOCK_BASE"
    end

    test "never calls exit, so `| iex` cannot close the person's PowerShell", %{conn: conn} do
      body = conn |> get("/cli/install.ps1") |> response(200)
      code = body |> String.split("\n") |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      refute Enum.any?(code, &(&1 =~ ~r/(^|[\s;{])exit(\s|$)/i))

      # Its preference is set inside its own block, never in the session's scope.
      [before_block, _] = String.split(body, "\n& {\n", parts: 2)
      refute before_block =~ "$ErrorActionPreference"
    end

    test "a Host that is not a plain name gets the configured address instead", %{conn: conn} do
      body =
        conn
        |> Map.put(:host, "evil.example'; Remove-Item C:\\")
        |> get("/cli/install.ps1")
        |> response(200)

      assert body =~ "$Base = '#{SlipdockWeb.Endpoint.url()}'"
      refute body =~ "evil.example"
    end
  end

  describe "GET /cli/slipdock.escript and /cli/SHA256SUMS" do
    test "serve the escript and the checksum of exactly those bytes", %{
      conn: conn,
      escript: escript
    } do
      bytes = "#!/usr/bin/env escript\n" <> :crypto.strong_rand_bytes(4096)
      File.write!(escript, bytes)

      served = get(conn, "/cli/slipdock.escript")
      assert response(served, 200) == bytes
      assert get_resp_header(served, "content-type") |> hd() =~ "application/octet-stream"

      sums = build_conn() |> get("/cli/SHA256SUMS") |> response(200)
      sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      assert sums == "#{sha}  slipdock.escript\n"
    end

    test "a server built without the CLI says so, for both", %{conn: conn} do
      assert conn |> get("/cli/slipdock.escript") |> response(404) =~
               "built without the slipdock CLI"

      assert build_conn() |> get("/cli/SHA256SUMS") |> response(404) =~ "built without"
    end

    test "a folder where the file should be is not served", %{conn: conn, escript: escript} do
      File.mkdir_p!(escript)
      assert conn |> get("/cli/slipdock.escript") |> response(404)
      assert build_conn() |> get("/cli/SHA256SUMS") |> response(404)
    end

    test "need no sign-in", %{escript: escript} do
      File.write!(escript, "x")
      assert Phoenix.ConnTest.build_conn() |> get("/cli/slipdock.escript") |> response(200) == "x"
    end
  end
end
