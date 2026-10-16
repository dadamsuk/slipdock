defmodule SlipdockWeb.ToolDownloadController do
  @moduledoc """
  A Tool's skill zips for somebody signed in to the web app (#963), which
  is how the claude.ai and ChatGPT steps on the Tool page download them: the
  API's copies need a token a browser doesn't send. A Tool the viewer can't
  see is a 404, the same as one that doesn't exist.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Tools

  def claude(conn, params), do: send_zip(conn, params, &Tools.claude_zip(&1, &2))

  def chatgpt(conn, params) do
    base = SlipdockWeb.BaseURL.from_conn(conn)
    send_zip(conn, params, &Tools.chatgpt_zip(&1, &2, base))
  end

  defp send_zip(conn, %{"slug" => slug, "skill" => skill} = params, build) do
    user = conn.assigns.current_user

    with {:ok, tool} <- Tools.fetch(user, slug),
         %{} = version <- Tools.visible_version(user, tool, params["version"]),
         {:ok, bytes} <- build.(version, skill) do
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{skill}.zip"))
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
