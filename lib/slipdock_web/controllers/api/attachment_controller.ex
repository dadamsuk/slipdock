defmodule SlipdockWeb.API.AttachmentController do
  @moduledoc """
  A file attached to a card or a wiki page, by its attachment id, for a
  token (#920). The web app's `/attachments/:id/:name` sits behind the
  browser's session, so `slipdock download` comes here instead.

  `GET /api/attachments/:id` is the file's details, as `attachments` lists
  them, plus the `card` or `page` it hangs off; `GET /api/attachments/:id/file`
  is its bytes, always as a download. Either is checked as reading that card
  or page is, with the token's scope narrowing it: a file the user can't see
  is a 404 like one that never was, and one their token is scoped away from
  is the 403 that says so.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Boards, Repo, Wiki}
  alias Slipdock.Boards.{Attachment, Card}
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.API.{Authorize, Uploads}
  alias SlipdockWeb.ByteRange

  action_fallback SlipdockWeb.API.FallbackController

  def show(conn, %{"id" => id}) do
    with {:ok, attachment} <- fetch(conn, id) do
      json(conn, %{attachment: attachment |> Uploads.json() |> Map.merge(owner(attachment))})
    end
  end

  def file(conn, %{"id" => id}) do
    with {:ok, attachment} <- fetch(conn, id) do
      path = Boards.attachment_path(attachment)

      if File.regular?(path) do
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> ByteRange.send(path, attachment.filename, attachment.content_type, :attachment)
      else
        {:error, :not_found, "the file's bytes"}
      end
    end
  end

  defp fetch(conn, id) do
    with {:ok, id} <- attachment_id(id),
         %Attachment{} = attachment <- Repo.get(Attachment, id),
         attachment = Repo.preload(attachment, [:card, :page]),
         true <- readable?(conn.assigns.current_user, attachment),
         :ok <- narrow(conn, attachment) do
      {:ok, attachment}
    else
      {:error, _, _} = refused -> refused
      _ -> {:error, :not_found, "attachment"}
    end
  end

  defp attachment_id(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :unprocessable_entity, "an attachment id is a number, like 42"}
    end
  end

  # What the user may read, before the token has its say. A view-only
  # reader's shared view is the web app's business: as `download_file`, a
  # token reads only what its user can read outright.
  defp readable?(user, %Attachment{card: %Card{} = card}),
    do: Access.can_read?(Access.card_permission(user, card))

  # A draft's files are as hidden as the draft.
  defp readable?(user, %Attachment{page: %Page{} = page}) do
    level = Access.page_permission(user, page)
    Access.can_read?(level) and Wiki.visible?(page, level)
  end

  defp readable?(_user, _attachment), do: false

  defp narrow(conn, %Attachment{card: %Card{} = card}), do: Authorize.card(conn, card, :read)
  defp narrow(conn, %Attachment{page: %Page{} = page}), do: Authorize.page(conn, page, :read)

  defp owner(%Attachment{card: %Card{id: id}}), do: %{card: id}
  defp owner(%Attachment{page: %Page{code: code}}), do: %{page: code}
end
