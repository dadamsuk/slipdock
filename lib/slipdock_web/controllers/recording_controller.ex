defmodule SlipdockWeb.RecordingController do
  @moduledoc """
  A meeting page's recording for the browser (W-1690): what the player's
  `<audio>` points at. Who may hear it is decided here, for a signed-in
  session; what is served, and how, is `SlipdockWeb.RecordingStream`. A token
  comes in by `SlipdockWeb.API.RecordingController`.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.RecordingStream

  def show(conn, %{"id" => id}) do
    with {n, ""} <- Integer.parse(id),
         %Page{archived_at: nil} = page <- Wiki.get_page(n),
         page = Wiki.with_board(page),
         true <- Access.can_read?(Access.board_permission(conn.assigns.current_user, page.board)) do
      RecordingStream.serve(conn, page)
    else
      _ -> RecordingStream.refuse(conn, 404, :not_found)
    end
  end
end
