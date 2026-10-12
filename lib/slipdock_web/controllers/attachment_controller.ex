defmodule SlipdockWeb.AttachmentController do
  @moduledoc """
  Serves files attached to cards and to wiki pages. Uploads live outside
  `priv/static`, so every download goes through here and is checked against
  the viewer's access to whatever the file hangs off. Raster images are shown
  inline, and so is audio, which a card plays in place; everything else is a
  download, so a pasted HTML or SVG file can never run in the app's origin.

  A `Range` request gets just those bytes (206): an audio player seeks with
  them, and Safari will not play a recording without them.
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

  # Anyone who can read the card, or a view-only reader of its board whose
  # shared view shows this card. Reaching the board through some view is not
  # enough: a card the view filters out keeps its files to itself.
  defp readable?(user, %Attachment{card: %Slipdock.Boards.Card{} = card}) do
    Access.can_read?(Access.card_permission(user, card)) or
      Access.view_shows_card?(user, card)
  end

  # A page's images are exactly as readable as the page: a draft's screenshot
  # is not a back door into a draft.
  defp readable?(user, %Attachment{page: %Page{} = page}) do
    Wiki.visible?(page, Access.page_permission(user, page))
  end

  defp readable?(_user, _attachment), do: false

  # One range, the only kind a media player asks for: `bytes=a-b`, `bytes=a-`
  # or `bytes=-n` (the last n). Several ranges, or a header that doesn't
  # parse, get the whole file, as the spec allows.
  defp byte_range(conn, size) do
    with ["bytes=" <> spec] <- get_req_header(conn, "range"),
         [from, to] <- String.split(spec, "-", parts: 2),
         {:ok, first, last} <- bounds(from, to, size) do
      if first <= last and first < size,
        do: {:range, first, min(last, size - 1), size},
        else: {:unsatisfiable, size}
    else
      :unsatisfiable -> {:unsatisfiable, size}
      _ -> :all
    end
  end

  defp bounds("", "", _size), do: :error

  defp bounds("", suffix, size) do
    case Integer.parse(suffix) do
      {0, ""} -> :unsatisfiable
      {n, ""} when n > 0 -> {:ok, max(size - n, 0), size - 1}
      _ -> :error
    end
  end

  defp bounds(from, to, size) do
    with {first, ""} when first >= 0 <- Integer.parse(from),
         {:ok, last} <- last_byte(to, size) do
      {:ok, first, last}
    else
      _ -> :error
    end
  end

  defp last_byte("", size), do: {:ok, size - 1}

  defp last_byte(to, _size) do
    case Integer.parse(to) do
      {last, ""} when last >= 0 -> {:ok, last}
      _ -> :error
    end
  end

  # As `send_download/3` writes it, so a range and a whole file name the file
  # the same way.
  defp disposition(type, filename) do
    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    ~s(#{type}; filename="#{encoded}"; filename*=utf-8''#{encoded})
  end

  defp send_attachment(conn, attachment) do
    path = Boards.attachment_path(attachment)

    if File.regular?(path) do
      disposition = if Attachment.inline?(attachment), do: :inline, else: :attachment

      conn =
        conn
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("accept-ranges", "bytes")

      case byte_range(conn, File.stat!(path).size) do
        :all ->
          send_download(conn, {:file, path},
            filename: attachment.filename,
            content_type: attachment.content_type,
            disposition: disposition
          )

        {:range, first, last, size} ->
          conn
          |> put_resp_content_type(attachment.content_type, nil)
          |> put_resp_header("content-disposition", disposition(disposition, attachment.filename))
          |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
          |> send_file(206, path, first, last - first + 1)

        {:unsatisfiable, size} ->
          conn
          |> put_resp_header("content-range", "bytes */#{size}")
          |> send_resp(416, "")
      end
    else
      conn
      |> put_status(:not_found)
      |> put_view(SlipdockWeb.ErrorHTML)
      |> render(:"404")
    end
  end
end
