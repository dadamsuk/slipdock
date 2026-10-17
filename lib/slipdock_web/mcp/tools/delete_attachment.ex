defmodule SlipdockWeb.MCP.Tools.DeleteAttachment do
  @moduledoc """
  Deletes a file from a card or a wiki page, by its attachment id (#1017):
  what `DELETE /api/cards/:id/attachments/:attachment_id` and its page twin
  do, so an agent can take back a file it uploaded wrong. Checked as editing
  that card or page is; a file the token can't read is not there at all.
  Nothing undoes it, so it wants `confirm: true`.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.{Attachment, Card}
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.ReadPage

  @impl true
  def name, do: "delete_attachment"

  @impl true
  def title, do: "Delete a file"

  @impl true
  def description,
    do:
      "Deletes a file from a card or wiki page by its attachment id (upload_file, get_card " <>
        "and read_page give it). Cannot be undone; needs confirm = true."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        attachment: %{type: "integer", description: "The attachment's id."},
        confirm: %{type: "boolean", description: "Must be true: this cannot be undone."}
      },
      required: ["attachment", "confirm"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- attachment_id(args),
         :ok <- Args.confirmed(args, "a file deleted is gone for good"),
         {:ok, attachment} <- fetch(id),
         :ok <- allowed(attachment, auth),
         {:ok, _} <- Args.refusal(Boards.delete_attachment(attachment)) do
      {:ok,
       Map.merge(
         %{deleted: true, attachment: id, filename: attachment.filename},
         owner(attachment)
       )}
    end
  end

  defp attachment_id(args) do
    case Args.id(args, "attachment") do
      {:ok, id} -> {:ok, id}
      {:error, "attachment is required"} = e -> e
      {:error, _} -> {:error, "attachment must be an attachment id, like 42"}
    end
  end

  defp fetch(id) do
    case Repo.get(Attachment, id) do
      nil -> not_found()
      attachment -> {:ok, Repo.preload(attachment, [:card, :page])}
    end
  end

  # Read first, so a file the token can't see is not there, as download_file
  # has it; then write, whose refusal says why.
  defp allowed(%Attachment{card: %Card{} = card}, auth) do
    case Authorize.card(auth, card, :read) do
      :ok -> Args.refusal(Authorize.card(auth, card, :write))
      _ -> not_found()
    end
  end

  defp allowed(%Attachment{page: %Page{} = page}, auth) do
    case ReadPage.check(page, auth, :read) do
      :ok -> ReadPage.check(page, auth, :write)
      _ -> not_found()
    end
  end

  defp allowed(_attachment, _auth), do: not_found()

  defp owner(%Attachment{card: %Card{id: id}}), do: %{card: id}
  defp owner(%Attachment{page: %Page{code: code}}), do: %{page: code}

  defp not_found, do: {:error, "no attachment you can see matches that"}
end
