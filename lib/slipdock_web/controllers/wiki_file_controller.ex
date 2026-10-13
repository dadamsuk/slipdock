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
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Repo}
  alias Slipdock.Wiki.{Files, Meld, WikiFile}

  def show(conn, %{"id" => id} = params) do
    with {n, ""} <- Integer.parse(id),
         %WikiFile{archived_at: nil} = file <- Files.get(n),
         file = Repo.preload(file, :board),
         true <- Access.can_read?(Access.board_permission(conn.assigns.current_user, file.board)),
         true <- File.regular?(Files.disk_path(file)) do
      if params["view"] == "locked" and Meld.note_file?(file.name),
        do: locked(conn, file),
        else: send_file(conn, file)
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
