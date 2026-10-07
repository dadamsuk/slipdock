defmodule SlipdockWeb.MCP.Tools.DeleteCard do
  @moduledoc """
  Deletes a card for good — its subcards, comments and attachments with it.
  `archive_card` is the undoable way to put one away, so this one has to be
  meant: it refuses without `confirm: true`.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "delete_card"

  @impl true
  def title, do: "Delete a card"

  @impl true
  def description,
    do:
      "Deletes a card and its subcards, comments and files. Cannot be undone; " <>
        "archive_card is the safe way. Needs confirm = true."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        confirm: %{type: "boolean", description: "Must be true: this cannot be undone."}
      },
      required: ["card", "confirm"],
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

    with {:ok, id} <- Args.id(args, "card"),
         :ok <- Args.confirmed(args, "archive_card puts it away and can be undone"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)),
         {:ok, _} <- Args.refusal(Boards.delete_card(card)) do
      {:ok, %{deleted: true, card: card.id, title: card.title, board_id: card.board_id}}
    end
  end
end
