defmodule SlipdockWeb.WikiFileController do
  @moduledoc """
  Serves the files in a board's wiki that are not pages (see
  `Slipdock.Wiki.WikiFile`) to whoever can read the board. Raster images are
  shown inline, which is what `![[diagram.png]]` draws; everything else —
  SVG and HTML included — is a download, so a synced file can never run in
  the app's origin.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Repo}
  alias Slipdock.Wiki.{Files, WikiFile}

  def show(conn, %{"id" => id}) do
    with {n, ""} <- Integer.parse(id),
         %WikiFile{archived_at: nil} = file <- Files.get(n),
         file = Repo.preload(file, :board),
         true <- Access.can_read?(Access.board_permission(conn.assigns.current_user, file.board)),
         true <- File.regular?(Files.disk_path(file)) do
      inline? = WikiFile.image?(file)

      conn
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:file, Files.disk_path(file)},
        filename: file.name,
        content_type: if(inline?, do: file.content_type, else: "application/octet-stream"),
        disposition: if(inline?, do: :inline, else: :attachment)
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
