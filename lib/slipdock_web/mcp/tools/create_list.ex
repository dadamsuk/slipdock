defmodule SlipdockWeb.MCP.Tools.CreateList do
  @moduledoc "A new list at the end of a board."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "create_list"

  @impl true
  def title, do: "Add a list"

  @impl true
  def description,
    do:
      "Adds a list (column) to the end of a board. category says what being in it " <>
        "means: todo is the ready list, doing in progress, done finished."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        name: %{type: "string"},
        category: %{type: "string", enum: Slipdock.Boards.Column.category_keys()},
        wip_limit: %{type: "integer", description: "Most cards it should hold."}
      },
      required: ["board", "name"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, name} <- Args.required(args, "name"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :write)),
         :ok <- unique(board, name),
         attrs = args |> Map.take(~w(category wip_limit)) |> Map.put("name", name),
         {:ok, column} <- Args.refusal(Boards.create_column(board, attrs)) do
      {:ok, %{list: SlipdockWeb.API.JSON.column(column), board_id: board.id}}
    end
  end

  # Lists are found by name everywhere else, so two of the same name would
  # leave the second one unreachable.
  defp unique(board, name) do
    case Boards.find_column(board, name) do
      {:ok, _} -> {:error, "#{board.name} already has a list called “#{name}”"}
      {:error, :not_found} -> :ok
    end
  end
end
