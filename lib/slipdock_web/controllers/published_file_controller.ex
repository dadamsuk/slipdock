defmodule SlipdockWeb.PublishedFileController do
  @moduledoc """
  The images a published wiki page embeds (#1166), served to anyone with the
  page's link: `/w/:token/files/:id/:name`.

  There is nobody behind the request to have permissions, so the page is the
  permission. The file is served only while the page is published, only when
  it is a raster image, and only when the page embeds it in a body somebody
  who could see the file saved (`Slipdock.Wiki.Embeds.published?/2`), so a
  sharee who edits the page cannot publish the rest of the owner's wiki
  through it. Unpublishing the page, or taking the embed out, closes it.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Embeds, Files, WikiFile}

  def show(conn, %{"token" => token, "id" => id}) do
    with {n, ""} <- Integer.parse(id),
         %Wiki.Page{} = page <- Wiki.get_published(token),
         %WikiFile{} = file <- Files.get(n),
         true <- Embeds.published?(page, file),
         true <- File.regular?(Files.disk_path(file)) do
      conn
      |> put_resp_header("cache-control", "public, max-age=300")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:file, Files.disk_path(file)},
        filename: file.name,
        content_type: file.content_type,
        disposition: :inline
      )
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(SlipdockWeb.ErrorHTML)
        |> render(:"404")
    end
  end
end
