defmodule SlipdockWeb.AttachmentController do
  @moduledoc """
  Serves files attached to cards and to wiki pages. Uploads live outside
  `priv/static`, so every download goes through here and is checked against
  the viewer's access to whatever the file hangs off. Raster images are shown
  inline; everything else is a download, so a pasted HTML or SVG file can
  never run in the app's origin.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Boards.Attachment
  alias Slipdock.Wiki.Page

  def show(conn, %{"id" => id}) do
    attachment = Boards.get_attachment!(id)
    user = conn.assigns.current_user

    if readable?(user, attachment) do
      send_attachment(conn, attachment)
    else
      conn
      |> put_status(:not_found)
      |> put_view(SlipdockWeb.ErrorHTML)
      |> render(:"404")
    end
  end

  # Anyone who can read the card, or who has any access to its board (a
  # view-only reader sees the card through a shared view).
  defp readable?(user, %Attachment{card: %Slipdock.Boards.Card{} = card}) do
    Access.can_read?(Access.card_permission(user, card)) or
      Access.board_permission(user, Boards.get_board!(card.board_id)) != :none
  end

  # A page's images are exactly as readable as the page: a draft's screenshot
  # is not a back door into a draft.
  defp readable?(user, %Attachment{page: %Page{} = page}) do
    Wiki.visible?(page, Access.page_permission(user, page))
  end

  defp readable?(_user, _attachment), do: false

  defp send_attachment(conn, attachment) do
    path = Boards.attachment_path(attachment)

    if File.regular?(path) do
      disposition = if Attachment.image?(attachment), do: :inline, else: :attachment

      conn
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:file, path},
        filename: attachment.filename,
        content_type: attachment.content_type,
        disposition: disposition
      )
    else
      conn
      |> put_status(:not_found)
      |> put_view(SlipdockWeb.ErrorHTML)
      |> render(:"404")
    end
  end
end
