defmodule SlipdockWeb.MCP.Tools.DeleteList do
  @moduledoc """
  Deletes a list. One that still holds cards is refused, as the HTTP API
  refuses it, unless `with_cards: true` says to delete them too.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "delete_list"

  @impl true
  def title, do: "Delete a list"

  @impl true
  def description,
    do:
      "Deletes an empty list from a board. A list holding cards is refused unless " <>
        "with_cards = true, which deletes them too and cannot be undone."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        list: %{type: "string", description: "List name or id."},
        with_cards: %{
          type: "boolean",
          description: "Delete the cards in it too, archived ones included (default false)."
        }
      },
      required: ["board", "list"],
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

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, list} <- Args.required(args, "list"),
         {:ok, with_cards} <- Args.boolean(args, "with_cards", false),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :write)),
         {:ok, column} <- column(board, list),
         {cards, archived} = Boards.column_card_counts(column),
         :ok <- empty_or_meant(column, cards, archived, with_cards),
         {:ok, _} <- Args.refusal(Boards.delete_column(column)) do
      {:ok, %{deleted: true, list: column.name, deleted_cards: cards, deleted_archived: archived}}
    end
  end

  defp column(board, ref) do
    case Boards.find_column(board, ref) do
      {:ok, column} ->
        {:ok, column}

      {:error, :not_found} ->
        names =
          board.id
          |> Boards.get_board!()
          |> Map.fetch!(:columns)
          |> Enum.map_join(", ", & &1.name)

        {:error, "#{board.name} has no list called “#{ref}”; its lists are: #{names}"}
    end
  end

  defp empty_or_meant(_column, 0, _archived, _with_cards), do: :ok
  defp empty_or_meant(_column, _cards, _archived, true), do: :ok

  defp empty_or_meant(column, cards, archived, false),
    do:
      {:error,
       "list_not_empty: “#{column.name}” still holds #{cards} card(s), #{archived} of them " <>
         "archived. Move them to another list first, or call again with with_cards = true " <>
         "to delete them with it, which cannot be undone."}
end
