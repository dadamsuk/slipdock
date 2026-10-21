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
        "Or instead: pulse (flow numbers), history (flow by day), runners, dora (delivery)."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{
          type: "string",
          description:
            "Board id, code or name. The answer has paused while runner work on it is held: stop."
        },
        pulse: %{
          type: "boolean",
          description:
            "The flow numbers instead of the lists: in progress, waiting, done in 7 days " <>
              "and today, P50/P85 seconds to done, moves in 24h forward and back, each " <>
              "list's in/out over 7 days and usual stay."
        },
        history: %{
          type: "boolean",
          description:
            "The flow day by day instead of the lists, over days (7, 30 or 90; 30 unless " <>
              "given): cards in backlog, ready, doing and done (since the window began), " <>
              "completed, open and added each day, completed per ISO week, and each card " <>
              "finished with its cycle seconds and their P50/P85."
        },
        runners: %{
          type: "boolean",
          description:
            "How the board's runners are doing instead of the lists, over days (7, 30 or " <>
              "90; 30 unless given): each runner's status and current job, outcomes, job " <>
              "and queue-wait P50/P85, success rate, waits on people, reopened cards, and " <>
              "the last 12 jobs."
        },
        dora: %{
          type: "boolean",
          description:
            "The DORA numbers instead of the lists, from the board's recorded deploys: " <>
              "deployment frequency, lead time P50/P85, change failure rate, time to restore " <>
              "P50/P85, rework rate and idea to production, each with its band and the window " <>
              "before. Says so when the board's delivery metrics are off."
        },
        environment: %{
          type: "string",
          description: "With dora: the environment (production unless given)."
        },
        days: %{
          type: "integer",
          description: "With dora, history or runners: the window in days (30 unless given)."
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
      cond do
        args["dora"] in [true, "true"] ->
          {:ok,
           board
           |> SlipdockWeb.API.JSON.dora(args["environment"], args["days"])
           |> Map.merge(%{name: board.name})}

        args["history"] in [true, "true"] ->
          {:ok,
           %{
             id: board.id,
             code: board.code,
             name: board.name,
             flow: Slipdock.Flow.history(board, days: args["days"])
           }}

        args["runners"] in [true, "true"] ->
          {:ok,
           %{
             id: board.id,
             code: board.code,
             name: board.name,
             runner_stats: Slipdock.RunnerStats.for_board(board, days: args["days"])
           }}

        args["pulse"] in [true, "true"] ->
          {:ok,
           %{
             id: board.id,
             code: board.code,
             name: board.name,
             pulse: Slipdock.Pulse.for_board(board)
           }
           |> Map.merge(SlipdockWeb.API.JSON.paused(board))}

        true ->
          lists(auth, board)
      end
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
     }
     |> Map.merge(SlipdockWeb.API.JSON.paused(board))}
  end

  defp role_of(roles, col) do
    Enum.find_value([:ready, :backlog, :doing, :done], fn role ->
      if roles[role] && roles[role].id == col.id, do: Atom.to_string(role)
    end)
  end
end
