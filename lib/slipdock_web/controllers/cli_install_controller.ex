defmodule SlipdockWeb.CLIInstallController do
  @moduledoc """
  The `slipdock` CLI for machines that have no checkout to build it from:

      GET /cli/install.sh         installs it on Linux and macOS, for one user, from here
      GET /cli/install.ps1        installs it on Windows, for one user, from here
      GET /cli/slipdock.escript   the CLI itself, an Erlang escript
      GET /cli/SHA256SUMS         its SHA-256, in `sha256sum -c` form
      GET /cli/slipdock.escript.sig  its signature with the project's release key

  The escript is built into the image (see the Dockerfile) at
  `priv/cli/slipdock.escript`, from the `cli/` this release was built from. A
  server run from a checkout has not built one, and says so with a 404 rather
  than serving something stale. The installers are the one thing that names
  this server, like `/install.ps1`, so they are written for whoever asks; the
  escript is the same bytes for everybody, which is what makes the checksum
  worth publishing.

  The signature (#2669, W-2542) is an OpenSSH signature in the namespace
  `slipdock-cli`, made by the release job, which builds the escript and
  signs it before the image is built; the image then serves those bytes and
  `priv/cli/slipdock.escript.sig` beside them. A server built any other way
  (from source, or an image from a commit the release job didn't sign) has
  none and answers 404, and the runner daemon then keeps the machine's own
  CLI unless its `local.json` sets `cli_checksum_only`.

  `/cli/install.sh` (#2826) checks the signature too, when one is served,
  with the release key's public half written into it from
  `daemon/internal/release/release_key.pub` (read at compile time: the
  Dockerfile copies it in before `mix compile`). It is not `/install.sh`,
  which installs the skills.
  """
  use SlipdockWeb, :controller

  @install_path Path.expand("../../../priv/cli/install.ps1", __DIR__)
  @external_resource @install_path
  @install File.read!(@install_path)

  @install_sh_path Path.expand("../../../priv/cli/install.sh", __DIR__)
  @external_resource @install_sh_path
  @install_sh File.read!(@install_sh_path)

  @release_key_source "daemon/internal/release/release_key.pub"
  @release_key_path Path.expand("../../../" <> @release_key_source, __DIR__)
  @external_resource @release_key_path
  @release_key (case File.read(@release_key_path) do
                  {:ok, text} ->
                    text
                    |> String.split("\n")
                    |> Enum.find("", &String.starts_with?(&1, "ssh-ed25519 "))
                    |> String.split(" ")
                    |> Enum.take(2)
                    |> Enum.join(" ")

                  {:error, _} ->
                    ""
                end)

  @missing "this server was built without the slipdock CLI\n"
  @unsigned "this server's slipdock CLI is not signed with the release key\n"

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

  @doc "Where the release key `/cli/install.sh` carries is read from, from the repository's root."
  def release_key_source, do: @release_key_source

  @doc "The release key's public half as `/cli/install.sh` carries it, or `\"\"`."
  def release_key, do: @release_key

  def install_sh(conn, _params) do
    base = SlipdockWeb.BaseURL.from_conn(conn)

    script =
      @install_sh
      |> String.replace("__SLIPDOCK_BASE_COMMENT__", base)
      |> String.replace("__SLIPDOCK_BASE__", sh_single_quoted(base))
      |> String.replace("__SLIPDOCK_RELEASE_KEY__", @release_key)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, script)
  end

  @doc """
  `text` made safe inside a single-quoted shell string, where only a quote
  means anything: it closes the string, gives a quote, and opens it again.
  BaseURL already refuses a Host that is not a plain name, so this is the
  second guard.
  """
  def sh_single_quoted(text), do: String.replace(text, "'", ~S('\''))

  # Not a hole: The escript's path is the release's own, not request input.
  # sobelow_skip ["Traversal.SendFile"]
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

  # Not a hole: the signature's path is the release's own, beside the escript.
  # sobelow_skip ["Traversal.FileModule"]
  def signature(conn, _params) do
    with {:ok, %{type: :regular}} <- File.stat(escript_path()),
         {:ok, sig} <- File.read(escript_path() <> ".sig") do
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, sig)
    else
      _ -> send_resp(conn, 404, @unsigned)
    end
  end

  # Configurable so the tests can stand a file in for the real build; the
  # runners' drift check (#1795) compares with the same file.
  defp escript_path, do: Slipdock.Runners.Drift.escript_path()
end
