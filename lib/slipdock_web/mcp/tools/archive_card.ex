defmodule SlipdockWeb.MCP.Tools.ArchiveCard do
  @moduledoc "Puts a card away, or brings an archived one back. There is no delete."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.{Args, Tools}

  @impl true
  def name, do: "archive_card"

  @impl true
  def title, do: "Archive a card"

  @impl true
  def description,
    do:
      "Archives a card: off the board and out of listings, kept and restorable. " <>
        "restore = true brings it back. Finished work goes to done, not here."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        restore: %{type: "boolean", description: "Unarchive instead (default false)."}
      },
      required: ["card"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, restore} <- Args.boolean(args, "restore", false),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)),
         {:ok, card} <- Args.refusal(change(card, restore)) do
      {:ok, Tools.card_written(Boards.get_card!(card.id), context.base_url)}
    end
  end

  # Asking for what is already so is answered with the card as it is.
  defp change(%{archived_at: nil} = card, true), do: {:ok, card}
  defp change(card, true), do: Boards.unarchive_card(card)
  defp change(%{archived_at: nil} = card, false), do: Boards.archive_card(card)
  defp change(card, false), do: {:ok, card}
end
