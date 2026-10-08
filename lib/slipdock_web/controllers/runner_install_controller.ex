defmodule SlipdockWeb.RunnerInstallController do
  @moduledoc """
  The shell runner and its installer, as plain text (see `Slipdock.Runners`):

      GET /runner/install.sh       the installer, with the runner inside it
      GET /runner/slipdock-runner  the runner on its own
      GET /runner/install.ps1          the same for Windows, PowerShell 5.1 or later
      GET /runner/slipdock-runner.ps1  the PowerShell runner on its own
      GET /runner/SHA256SUMS       every file's SHA-256, in `sha256sum -c` form
      GET /runner/examples/NAME    a worked example of runner hooks, and its test
                                   (see `Slipdock.Runners.HookPrompt`)

  Unlike `/install.sh` these are static — the same bytes for every caller on
  every server running this release, with nothing about the server or the
  person written in — so a published checksum means something. Where to
  connect and with which token are the installer's arguments instead.
  """
  use SlipdockWeb, :controller

  @runner_path Path.expand("../../../priv/runner/slipdock-runner", __DIR__)
  @install_path Path.expand("../../../priv/runner/install.sh", __DIR__)
  @ps_runner_path Path.expand("../../../priv/runner/slipdock-runner.ps1", __DIR__)
  @ps_install_path Path.expand("../../../priv/runner/install.ps1", __DIR__)
  @external_resource @runner_path
  @external_resource @install_path
  @external_resource @ps_runner_path
  @external_resource @ps_install_path

  @runner File.read!(@runner_path)
  @install @install_path
           |> File.read!()
           |> String.replace("__SLIPDOCK_RUNNER__\n", @runner, global: false)

  @ps_runner File.read!(@ps_runner_path) |> String.trim_trailing()
  @ps_install @ps_install_path
              |> File.read!()
              |> String.replace("__SLIPDOCK_RUNNER_PS1__", @ps_runner, global: false)

  @sums Enum.map_join(
          [
            {"install.sh", @install},
            {"slipdock-runner", @runner},
            {"install.ps1", @ps_install},
            {"slipdock-runner.ps1", @ps_runner <> "\n"}
          ],
          fn {name, body} ->
            Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> "  " <> name <> "\n"
          end
        )

  @examples_dir Path.expand("../../../priv/runner/examples", __DIR__)
  @examples Map.new(Slipdock.Runners.HookPrompt.example_files(), fn name ->
              path = Path.join(@examples_dir, name)
              @external_resource path
              {name, File.read!(path)}
            end)

  @doc false
  def examples, do: @examples

  @doc false
  def files,
    do: %{
      "install.sh" => @install,
      "slipdock-runner" => @runner,
      "install.ps1" => @ps_install,
      "slipdock-runner.ps1" => @ps_runner <> "\n",
      "SHA256SUMS" => @sums
    }

  def install(conn, _params), do: text_file(conn, @install)
  def runner(conn, _params), do: text_file(conn, @runner)
  def sums(conn, _params), do: text_file(conn, @sums)
  def install_ps1(conn, _params), do: text_file(conn, @ps_install)
  def runner_ps1(conn, _params), do: text_file(conn, @ps_runner <> "\n")

  def example(conn, %{"name" => name}) do
    case Map.fetch(@examples, name) do
      {:ok, body} -> text_file(conn, body)
      :error -> send_resp(conn, 404, "no such example\n")
    end
  end

  defp text_file(conn, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, body)
  end
end
