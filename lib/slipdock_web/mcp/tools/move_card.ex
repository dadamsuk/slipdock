defmodule SlipdockWeb.MCP.Tools.MoveCard do
  @moduledoc "Moves a card to another list on its board, or within its list."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.{Args, Tools}

  @impl true
  def name, do: "move_card"

  @impl true
  def title, do: "Move a card"

  @impl true
  def description,
    do:
      "Moves a card to a list on its board: to the doing list when you start it. " <>
        "To finish a card use complete_card, which also marks it done."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        column: %{type: "string", description: "List name or id; default the list it is in."},
        position: %{type: "string", enum: ["top", "bottom"], description: "Default top."}
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
         {:ok, ref} <- Args.optional(args, "column"),
         {:ok, index} <- position(args["position"]),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)),
         board = Boards.get_board!(card.board_id),
         {:ok, column} <- Args.refusal(CardWrites.resolve_column(board, ref || card.column_id)),
         :ok <- Boards.move_card_to_index(card, column, index) do
      {:ok, Tools.card_written(Boards.get_card!(card.id), context.base_url)}
    end
  end

  defp position(p) when p in [nil, "top"], do: {:ok, :top}
  defp position("bottom"), do: {:ok, :bottom}
  defp position(_), do: {:error, "position must be top or bottom"}
end
