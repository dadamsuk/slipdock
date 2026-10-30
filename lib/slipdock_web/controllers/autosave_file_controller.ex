defmodule SlipdockWeb.AutosaveFileController do
  @moduledoc """
  Serves an image held for a page that has not been saved yet, to the one
  person writing it (#1532): the editor's preview shows it from here. Only
  raster images are ever held, so it is safe inline.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Wiki.Autosaves
  alias SlipdockWeb.ByteRange

  def show(conn, %{"id" => id}) do
    file =
      case Integer.parse(id) do
        {id, ""} -> Autosaves.get_file(conn.assigns.current_user, id)
        _ -> nil
      end

    if file && File.regular?(Autosaves.file_path(file)) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> ByteRange.send(Autosaves.file_path(file), file.filename, file.content_type, :inline)
    else
      conn
      |> put_status(:not_found)
      |> put_view(SlipdockWeb.ErrorHTML)
      |> render(:"404")
    end
  end
end
