defmodule SlipdockWeb.DeployExamplesController do
  @moduledoc """
  The worked examples of recording deploys from CI (#1134, see
  `Slipdock.Deployments.Setup`), as plain text:

      GET /deploy/examples/github-actions.yml
      GET /deploy/examples/gitlab-ci.yml
      GET /deploy/examples/deploy.sh
      GET /deploy/examples/curl.sh

  Static, like the runner's: nothing about the server or the person is
  written in, so the setup prompt can point an agent at them.
  """
  use SlipdockWeb, :controller

  @examples_dir Path.expand("../../../priv/deploy/examples", __DIR__)
  @examples Map.new(Slipdock.Deployments.Setup.example_files(), fn name ->
              path = Path.join(@examples_dir, name)
              @external_resource path
              {name, File.read!(path)}
            end)

  @doc false
  def examples, do: @examples

  def show(conn, %{"name" => name}) do
    case Map.fetch(@examples, name) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "no such example\n")
    end
  end
end
