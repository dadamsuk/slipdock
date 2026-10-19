defmodule SlipdockWeb.MCP.Tools.GetBoard do
  @moduledoc "One board: its lists in order and the cards on each, briefly."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.{Args, Tools}

  @impl true
  def name, do: "get_board"

  @impl true
  def title, do: "Get a board"

  @impl true
  def description,
    do:
      "A board's lists in order with a summary of each card, description included. " <>
        "Board is an id, code or name. Use get_card for a card's comments and checklist. " <>
        "pulse: true gives the board's flow numbers instead of its lists."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        pulse: %{
          type: "boolean",
          description:
            "The flow numbers instead of the lists: in progress, waiting, done in 7 days " <>
              "and today, P50/P85 seconds to done, moves in 24h forward and back, each " <>
              "list's in/out over 7 days and usual stay."
        }
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :read)) do
      if args["pulse"] in [true, "true"],
        do:
          {:ok,
           %{
             id: board.id,
             code: board.code,
             name: board.name,
             pulse: Slipdock.Pulse.for_board(board)
           }},
        else: lists(auth, board)
    end
  end

  defp lists(auth, board) do
    board = Authorize.visible(auth, Boards.get_board!(board.id))
    roles = SlipdockWeb.APIGuide.list_roles(board.columns)

    {:ok,
     %{
       id: board.id,
       code: board.code,
       name: board.name,
       description: board.description,
       simple: board.simple,
       parent_card:
         board.parent_card && %{id: board.parent_card.id, title: board.parent_card.title},
       tags: Enum.map(board.tags, & &1.name),
       lists:
         Enum.map(board.columns, fn col ->
           %{
             name: col.name,
             role: role_of(roles, col),
             wip_limit: col.wip_limit,
             cards: Enum.map(col.cards, &Tools.card_line/1)
           }
         end)
     }}
  end

  defp role_of(roles, col) do
    Enum.find_value([:ready, :backlog, :doing, :done], fn role ->
      if roles[role] && roles[role].id == col.id, do: Atom.to_string(role)
    end)
  end
end
