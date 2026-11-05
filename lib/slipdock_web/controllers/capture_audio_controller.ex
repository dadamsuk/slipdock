defmodule SlipdockWeb.CaptureAudioController do
  @moduledoc """
  A capture's recording, for replaying a passage: to anybody who can read
  the capture's board, while meeting mode is on for them (#1206) and the recording is still
  kept. Answers byte ranges, so a player can jump to the second it is asked
  for (`/captures/12/audio#t=458,464`).
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Boards, Meetings}

  def show(conn, %{"id" => id}) do
    with true <- Meetings.enabled_for?(conn.assigns.current_user),
         %Meetings.Capture{} = capture <- Meetings.get_capture(SlipdockWeb.Params.id(id) || 0),
         board = Boards.get_board!(capture.board_id),
         true <- Access.can_read?(Access.board_permission(conn.assigns.current_user, board)),
         path when is_binary(path) <- Meetings.audio_path(capture),
         true <- File.regular?(path) do
      send_range(conn, path, playable_type(capture.audio_content_type || MIME.from_path(path)))
    else
      _ -> conn |> put_status(:not_found) |> put_view(SlipdockWeb.ErrorHTML) |> render(:"404")
    end
  end

  # The type the sender gave is only used when it is a recording's: anything
  # else is served as plain bytes to download, so a file sent with a page's
  # or a script's type is never treated as one from this origin.
  defp playable_type(type) do
    case SlipdockWeb.ByteRange.inline_type(type) do
      "image/" <> _ -> "application/octet-stream"
      type -> type
    end
  end

  # Not a hole: Server-made path; the type is playable_type/1's (a bare audio or video type, else bytes).
  # sobelow_skip ["Traversal.SendFile", "XSS.ContentType"]
  defp send_range(conn, path, type) do
    size = File.stat!(path).size

    conn =
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> disposition(type)

    case range(get_req_header(conn, "range"), size) do
      {from, to} ->
        conn
        |> put_resp_header("content-range", "bytes #{from}-#{to}/#{size}")
        |> send_file(206, path, from, to - from + 1)

      nil ->
        send_file(conn, 200, path)
    end
  end

  defp disposition(conn, "application/octet-stream"),
    do: put_resp_header(conn, "content-disposition", "attachment")

  defp disposition(conn, _type), do: conn

  # One range, "bytes=from-" or "bytes=from-to", within the file.
  defp range(["bytes=" <> spec | _], size) do
    case String.split(spec, "-", parts: 2) do
      [from, to] ->
        with {f, ""} <- Integer.parse(from),
             t =
               (case Integer.parse(to) do
                  {t, ""} -> min(t, size - 1)
                  _ -> size - 1
                end),
             true <- f <= t do
          {f, t}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp range(_, _), do: nil
end
