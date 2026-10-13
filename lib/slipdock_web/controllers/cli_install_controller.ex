defmodule SlipdockWeb.CLIInstallController do
  @moduledoc """
  The `slipdock` CLI for machines that have no checkout to build it from:

      GET /cli/install.ps1        installs it on Windows, for one user, from here
      GET /cli/slipdock.escript   the CLI itself, an Erlang escript
      GET /cli/SHA256SUMS         its SHA-256, in `sha256sum -c` form

  The escript is built into the image (see the Dockerfile) at
  `priv/cli/slipdock.escript`, from the `cli/` this release was built from. A
  server run from a checkout has not built one, and says so with a 404 rather
  than serving something stale. The installer is the one thing that names
  this server, like `/install.ps1`, so it is written for whoever asks; the
  escript is the same bytes for everybody, which is what makes the checksum
  worth publishing.
  """
  use SlipdockWeb, :controller

  @install_path Path.expand("../../../priv/cli/install.ps1", __DIR__)
  @external_resource @install_path
  @install File.read!(@install_path)

  @missing "this server was built without the slipdock CLI\n"

  def install_ps1(conn, _params) do
    base = SlipdockWeb.BaseURL.from_conn(conn)

    script =
      @install
      |> String.replace("__SLIPDOCK_BASE_COMMENT__", base)
      # BaseURL already refuses a Host that is not a plain name; in a
      # single-quoted PowerShell string only a quote means anything, doubled.
      |> String.replace("__SLIPDOCK_BASE__", String.replace(base, "'", "''"))

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, script)
  end

  def escript(conn, _params) do
    case File.stat(escript_path()) do
      {:ok, %{type: :regular}} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("content-disposition", ~s(attachment; filename="slipdock.escript"))
        |> put_resp_header("cache-control", "no-cache")
        |> send_file(200, escript_path())

      _ ->
        send_resp(conn, 404, @missing)
    end
  end

  def sums(conn, _params) do
    case File.read(escript_path()) do
      {:ok, body} ->
        sum = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, sum <> "  slipdock.escript\n")

      {:error, _} ->
        send_resp(conn, 404, @missing)
    end
  end

  # Configurable so the tests can stand a file in for the real build.
  defp escript_path do
    Application.get_env(:slipdock, :cli_escript) ||
      Application.app_dir(:slipdock, "priv/cli/slipdock.escript")
  end
end
