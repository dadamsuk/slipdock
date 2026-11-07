defmodule SlipdockWeb.API.GuideController do
  @moduledoc """
  `GET /api/guide` — the API's own instructions, written for an agent: the
  model, the epic/subcard convention, how to pick the next thing to do, and
  what to write back while doing it.

  No token is needed to read it (there is nothing private in the prose), but a
  token earns the reader a closing section listing their own boards and lists.
  `?section=short|all|<key>` serves one cut of it (`APIGuide.section/2`).
  """
  use SlipdockWeb, :controller

  alias SlipdockWeb.APIGuide

  def show(conn, params) do
    opts = [
      base_url: base_url(conn),
      user: conn.assigns[:current_user],
      token: conn.assigns[:api_token]
    ]

    case params["section"] do
      key when key in [nil, "", "all"] -> whole(conn, params, opts)
      key -> section(conn, params, opts, String.downcase(key))
    end
  end

  # No `section` (or `all`): the whole guide, exactly as it has always been
  # served, since the plain URL is quoted in prompts and docs.
  defp whole(conn, params, opts) do
    if json?(conn, params) do
      json(conn, APIGuide.json(opts))
    else
      markdown(conn, 200, APIGuide.markdown(opts))
    end
  end

  # `?section=short` or a key: the text `APIGuide.section/2` gives, the same
  # cut `get_guide` serves. An unknown key is a 404 whose message lists them.
  defp section(conn, params, opts, key) do
    case {APIGuide.section(key, opts), json?(conn, params)} do
      {{:ok, text}, true} ->
        json(conn, opts |> APIGuide.json() |> Map.merge(%{section: key, guide: text}))

      {{:ok, text}, false} ->
        markdown(conn, 200, text)

      {{:error, message}, true} ->
        conn |> put_status(404) |> json(%{error: "unknown_section", message: message})

      {{:error, message}, false} ->
        markdown(conn, 404, message <> "\n")
    end
  end

  defp markdown(conn, status, text) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(status, text)
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

  # The address the caller actually reached us on — `SlipdockWeb.BaseURL` has
  # the reasoning. Every curl block in the guide is built from this, so an
  # agent can copy one and have it work.
  defp base_url(conn), do: SlipdockWeb.BaseURL.from_conn(conn)
end
