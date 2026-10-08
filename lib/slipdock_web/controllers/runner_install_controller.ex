defmodule SlipdockWeb.RunnerInstallController do
  @moduledoc """
  The shell runner and its installer, as plain text (see `Slipdock.Runners`):

      GET /runner/install.sh       the installer, with the runner inside it
      GET /runner/slipdock-runner  the runner on its own
      GET /runner/SHA256SUMS       both files' SHA-256, in `sha256sum -c` form

  Unlike `/install.sh` these are static — the same bytes for every caller on
  every server running this release, with nothing about the server or the
  person written in — so a published checksum means something. Where to
  connect and with which token are the installer's arguments instead.
  """
  use SlipdockWeb, :controller

  @runner_path Path.expand("../../../priv/runner/slipdock-runner", __DIR__)
  @install_path Path.expand("../../../priv/runner/install.sh", __DIR__)
  @external_resource @runner_path
  @external_resource @install_path

  @runner File.read!(@runner_path)
  @install @install_path
           |> File.read!()
           |> String.replace("__SLIPDOCK_RUNNER__\n", @runner, global: false)

  @sums Enum.map_join(
          [{"install.sh", @install}, {"slipdock-runner", @runner}],
          fn {name, body} ->
            Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> "  " <> name <> "\n"
          end
        )

  @doc false
  def files, do: %{"install.sh" => @install, "slipdock-runner" => @runner, "SHA256SUMS" => @sums}

  def install(conn, _params), do: text_file(conn, @install)
  def runner(conn, _params), do: text_file(conn, @runner)
  def sums(conn, _params), do: text_file(conn, @sums)

  defp text_file(conn, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, body)
  end
end
