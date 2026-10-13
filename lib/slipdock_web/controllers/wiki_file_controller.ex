defmodule SlipdockWeb.WikiFileController do
  @moduledoc """
  Serves the files in a board's wiki that are not pages (see
  `Slipdock.Wiki.WikiFile`) to whoever can read the board. Raster images are
  shown inline, which is what `![[diagram.png]]` draws; everything else —
  SVG and HTML included — is a download, so a synced file can never run in
  the app's origin.

  A whole note Meld Encrypt wrote (`.mdenc`) is also shown, with
  `?view=locked`, as a locked page the browser can decrypt (W-103 R6.1):
  the server hands over the ciphertext it has and nothing more.

  The file viewer (`SlipdockWeb.FileLive`) asks for a PDF or an SVG with
  `?view=inline`, to show it rather than download it: a PDF goes to the
  browser's own PDF viewer, and an SVG comes with a policy that lets it run
  nothing and fetch nothing, the same one a drawing's preview has. An HTML
  file is shown the same way (#768): the policy's `sandbox` gives it an
  origin of its own, with no scripts, no forms and nothing fetched, so it
  is a document to read and never code running as the reader. An audio
  file (#770) is served as audio, a byte range at a time when the player
  asks for one (`SlipdockWeb.ByteRange`), so it can seek.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Repo}
  alias Slipdock.Wiki.{Files, Meld, Viewer, WikiFile}
  alias SlipdockWeb.ByteRange

  @svg_policy "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox"
  @html_policy "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; sandbox"

  def show(conn, %{"id" => id} = params) do
    with {n, ""} <- Integer.parse(id),
         %WikiFile{archived_at: nil} = file <- Files.get(n),
         file = Repo.preload(file, :board),
         true <- Access.can_read?(Access.board_permission(conn.assigns.current_user, file.board)),
         true <- File.regular?(Files.disk_path(file)) do
      cond do
        params["view"] == "locked" and Meld.note_file?(file.name) -> locked(conn, file)
        params["view"] == "inline" -> inline(conn, file, Viewer.kind(file))
        true -> send_file(conn, file)
      end
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(SlipdockWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp locked(conn, file) do
    json = File.read!(Files.disk_path(file))

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_view(SlipdockWeb.WikiFileHTML)
    |> render(:locked,
      file: file,
      note: Meld.parse_note(json),
      json: json,
      download: Files.url(file),
      page_title: file.name
    )
  end

  defp inline(conn, file, :pdf), do: send_inline(conn, file, "application/pdf")

  defp inline(conn, file, :svg) do
    conn
    |> put_resp_header("content-security-policy", @svg_policy)
    |> send_inline(file, "image/svg+xml")
  end

  defp inline(conn, file, :html) do
    conn
    |> put_resp_header("content-security-policy", @html_policy)
    |> put_resp_header("referrer-policy", "no-referrer")
    |> send_inline(file, "text/html; charset=utf-8")
  end

  defp inline(conn, file, :audio) do
    conn
    |> put_resp_header("cache-control", "private, max-age=86400")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> ByteRange.send(Files.disk_path(file), file.name, MIME.from_path(file.name), :inline)
  end

  defp inline(conn, file, _kind), do: send_file(conn, file)

  defp send_inline(conn, file, type) do
    conn
    |> put_resp_header("cache-control", "private, max-age=86400")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_download({:file, Files.disk_path(file)},
      filename: file.name,
      content_type: type,
      disposition: :inline
    )
  end

  defp send_file(conn, file) do
    inline? = WikiFile.image?(file)

    conn
    |> put_resp_header("cache-control", "private, max-age=86400")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_download({:file, Files.disk_path(file)},
      filename: file.name,
      content_type: if(inline?, do: file.content_type, else: "application/octet-stream"),
      disposition: if(inline?, do: :inline, else: :attachment)
    )
  end
end
