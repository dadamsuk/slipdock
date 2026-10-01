defmodule SlipdockWeb.API.GuideController do
  @moduledoc """
  `GET /api/guide` — the API's own instructions, written for an agent: the
  model, the epic/subcard convention, how to pick the next thing to do, and
  what to write back while doing it.

  No token is needed to read it (there is nothing private in the prose), but a
  token earns the reader a closing section listing their own boards and lists.
  """
  use SlipdockWeb, :controller

  alias SlipdockWeb.APIGuide

  def show(conn, params) do
    opts = [base_url: base_url(conn), user: conn.assigns[:current_user]]

    if json?(conn, params) do
      json(conn, APIGuide.json(opts))
    else
      conn
      |> put_resp_content_type("text/markdown")
      |> send_resp(200, APIGuide.markdown(opts))
    end
  end

  # Markdown by default — `curl` and agents read it as it is. `?format=json`,
  # or an explicitly JSON Accept header, gets the structured version.
  defp json?(conn, params) do
    case params["format"] do
      "json" -> true
      f when f in ~w(md markdown text txt) -> false
      _ -> Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "application/json"))
    end
  end

  defp base_url(conn) do
    port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port}"
  end
end
