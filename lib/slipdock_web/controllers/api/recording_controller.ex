defmodule SlipdockWeb.API.RecordingController do
  @moduledoc """
  A meeting page's recording for a client holding an API token (#1562): the
  same stream as the browser's (`SlipdockWeb.RecordingStream`), behind the
  token's own limits.

  Hearing it takes read on the board, as in the browser, and a draft page's
  takes write, like the draft itself (`Slipdock.Wiki.visible?/2`). A page
  shared with someone outside the board stays silent: playing it would hand
  them the owner's Drive audio, and that is a decision of its own. A token
  limited to other boards gets the API's usual 403, which says the token is
  why. Anything the person can't read is a 404, as if it weren't there.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.RecordingStream

  action_fallback SlipdockWeb.API.FallbackController

  def show(conn, %{"id" => ref}) do
    user = conn.assigns.current_user

    with {:ok, %Page{archived_at: nil} = page} <- Wiki.find_page(ref, as: user),
         board = Wiki.board_of(page),
         true <- Wiki.visible?(page, Access.board_permission(user, board)),
         :ok <- Authorize.board(conn, board, :read) do
      RecordingStream.serve(conn, page)
    else
      {:error, :forbidden, _} = refused -> refused
      _ -> RecordingStream.refuse(conn, 404, :not_found)
    end
  end
end
