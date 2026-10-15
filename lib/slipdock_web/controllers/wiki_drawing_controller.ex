defmodule SlipdockWeb.WikiDrawingController do
  @moduledoc """
  An Excalidraw drawing's preview, as SVG (W-103 R5.1): what a page that
  embeds `![[x.excalidraw]]` draws with an `<img>`, for whoever can read the
  drawing. The SVG is made on the server from the scene
  (`Slipdock.Wiki.Excalidraw.SVG`) and sent with a policy that lets it run
  nothing and fetch nothing, should anyone open it on its own.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Repo
  alias Slipdock.Wiki.{Drawings, Embeds, Page, WikiFile}

  @policy "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox"

  def show(conn, %{"kind" => kind, "id" => id} = params) do
    with {n, ""} <- Integer.parse(id),
         drawing when not is_nil(drawing) <- fetch(kind, n),
         true <- readable?(drawing, conn.assigns.current_user, params),
         {:ok, svg} <- Drawings.svg(drawing, conn.assigns.current_user) do
      conn
      |> put_resp_content_type("image/svg+xml")
      |> put_resp_header("content-security-policy", @policy)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_resp(200, svg)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(SlipdockWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  # The reader's own, or a `.excalidraw` file embedded in a page they can
  # read, named by `?page=` (#832, `Slipdock.Wiki.Embeds`).
  defp readable?(drawing, user, params) do
    Drawings.readable?(drawing, user) or
      (match?(%WikiFile{}, drawing) and Embeds.reaches?(user, Embeds.page_param(params), drawing))
  end

  defp fetch("page", id), do: Repo.get(Page, id)
  defp fetch("file", id), do: Repo.get(WikiFile, id)
  defp fetch(_kind, _id), do: nil
end
