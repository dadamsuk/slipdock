defmodule SlipdockWeb.API.TransferController do
  @moduledoc """
  The far end of a short-lived, single-use link (#1147): `POST
  /api/upload/:secret` attaches a file to the one card or page the link was
  made for, and `GET /api/download/:secret` sends the one attachment it was
  made for, or the one piece of a Tool version: its skills archive, a
  skill's claude.ai zip or a file (#1158). No bearer token: the secret in the URL is the authority, and it
  acts as the token that minted it (see `Slipdock.TransferLinks`).

  An upload takes what `POST /api/cards/:id/attachments` takes — the
  multipart `file`, and `sha256`, `replace`, `filename`, `hide_on_card` —
  and answers as it does. The access checks are that endpoint's, made again
  now, so a token narrowed or a card shared away since the link was made
  stops it. A refused use leaves the link good until it expires.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Boards, Tools, TransferLinks, Wiki}
  alias Slipdock.Boards.{Attachment, Card}
  alias Slipdock.TransferLinks.Link
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.API.{Authorize, Uploads}
  alias SlipdockWeb.ByteRange

  action_fallback SlipdockWeb.API.FallbackController

  def upload(conn, %{"secret" => secret} = params) do
    with {:ok, link} <- claim(conn, secret, "upload") do
      conn = as(conn, link)

      case store(conn, link, params) do
        {:ok, answer} ->
          conn |> put_status(:created) |> json(answer)

        refused ->
          TransferLinks.release(link)
          refused
      end
    end
  end

  def download(conn, %{"secret" => secret}) do
    with {:ok, link} <- claim(conn, secret, "download") do
      conn = as(conn, link)
      send_link(conn, link)
    end
  end

  # A Tool's piece is checked as the Tool page is: the version must still be
  # one this user sees (their own, shared with them, or the listed one).
  defp send_link(conn, %Link{tool_version: %Tools.Version{} = version} = link) do
    user = conn.assigns.current_user

    with %Tools.Version{id: id} <- Tools.visible_version(user, version.tool, version.version),
         true <- id == version.id,
         {:ok, type, filename, bytes} <- tool_piece(version, link.tool_target) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("x-tool-version", version.version)
      |> put_resp_content_type(type, nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, bytes)
    else
      _ ->
        TransferLinks.release(link)
        {:error, :not_found, "Tool #{inspect(version.tool.slug)} #{version.version}"}
    end
  end

  defp send_link(conn, link) do
    attachment = link.attachment
    path = Boards.attachment_path(attachment)

    with :ok <- readable(conn, attachment),
         true <- File.regular?(path) || {:error, :not_found, "the file's bytes"} do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> ByteRange.send(path, attachment.filename, attachment.content_type, :attachment)
    else
      refused ->
        TransferLinks.release(link)
        refused
    end
  end

  defp tool_piece(version, "archive") do
    with {:ok, bytes} <- Tools.skills_tarball(version),
         do: {:ok, "application/gzip", "#{version.tool.slug}-skills.tar.gz", bytes}
  end

  defp tool_piece(version, "claude:" <> skill) do
    with {:ok, bytes} <- Tools.claude_zip(version, skill),
         do: {:ok, "application/zip", "#{skill}.zip", bytes}
  end

  defp tool_piece(version, "file:" <> path) do
    case Tools.file(version, path) do
      nil -> :error
      file -> {:ok, "application/octet-stream", Path.basename(path), file.content}
    end
  end

  defp tool_piece(_version, _target), do: :error

  # One answer for a link that is used, expired, revoked or never was: a
  # halted conn, which the with hands straight back.
  defp claim(conn, secret, kind) do
    case TransferLinks.claim(secret, kind) do
      {:ok, link} -> {:ok, link}
      {:error, :gone} -> gone(conn)
    end
  end

  defp gone(conn) do
    conn
    |> put_status(:gone)
    |> json(%{
      error:
        "link_gone: this link has been used, has expired or was never made. Ask for a new " <>
          "one (upload_file or download_file with link: true); each works once, for " <>
          "#{div(TransferLinks.ttl_seconds(), 60)} minutes."
    })
  end

  # The request, as though the token that made the link had sent it.
  defp as(conn, %Link{user: user, user_token: token}) do
    conn
    |> assign(:current_user, user)
    |> assign(:api_token, token)
    |> assign(:actor, Slipdock.Actor.from_conn(assign(conn, :api_token, token)))
  end

  defp store(conn, %Link{card: %Card{} = card}, params) do
    with :ok <- Authorize.card(conn, card, :write),
         {:ok, meta, path} <- Uploads.take(params),
         {:ok, replace?} <- Uploads.replace(params),
         {:ok, attachment} <- Boards.add_attachment(card, meta, path) do
      {:ok, Uploads.stored(attachment, replace?)}
    end
  end

  defp store(conn, %Link{page: %Page{} = page}, params) do
    with :ok <- page_visible(conn, page),
         :ok <- Authorize.page(conn, page, :write),
         {:ok, meta, path} <- Uploads.take(params),
         {:ok, replace?} <- Uploads.replace(params),
         {:ok, attachment} <- Wiki.add_attachment(page, meta, path) do
      {:ok, Uploads.stored(attachment, replace?)}
    end
  end

  defp readable(conn, %Attachment{card: %Card{} = card}) do
    if Access.can_read?(Access.card_permission(conn.assigns.current_user, card)),
      do: Authorize.card(conn, card, :read),
      else: {:error, :not_found, "attachment"}
  end

  defp readable(conn, %Attachment{page: %Page{} = page}) do
    with :ok <- page_visible(conn, page), do: Authorize.page(conn, page, :read)
  end

  defp readable(_conn, _attachment), do: {:error, :not_found, "attachment"}

  # A draft, and a page the user can't read at all, are not there.
  defp page_visible(conn, page) do
    level = Access.page_permission(conn.assigns.current_user, page)

    if Access.can_read?(level) and Wiki.visible?(page, level),
      do: :ok,
      else: {:error, :not_found, "page"}
  end
end
