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
        "Board is an id, code or name. get_card has a card's comments and checklist. " <>
        "Or instead: pulse (flow numbers), history (flow by day), runners, dora (delivery), " <>
        "overseer, now."

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
        overseer: %{
          type: "boolean",
          description:
            "The overseer instead of the lists (#2068): on or off, its pacing bounds, next " <>
              "pass, last digest, and its open conditions (looping, waiting while idle, slow, " <>
              "idle capacity, no way forward), each with why and what to do."
        },
        now: %{
          type: "boolean",
          description:
            "What is happening right now on the board's tree instead of the lists (#2103): " <>
              "each runner, online or not, and the jobs it holds with their latest step; " <>
              "every card in progress with its board, list, parent epic, state line and " <>
              "what holds it (waiting, verifying, merging, blocked, review, stuck, " <>
              "over_usual); the " <>
              "jobs queued and why each is held; and the counts."
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

        Enum.member?([true, "true"], args["overseer"]) ->
          overseer(auth, board)

        Enum.member?([true, "true"], args["now"]) ->
          right_now(auth, board)

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

  # The overseer of `board`'s tree answers for its root, so it needs read
  # on the root too (#2068): its conditions and digest name the root's cards
  # and its sibling sub-boards'.
  defp overseer(auth, board) do
    with {:ok, root} <- Args.refusal(Authorize.tree_root(auth, board, :read)) do
      {:ok,
       %{
         id: board.id,
         code: board.code,
         name: board.name,
         overseer: SlipdockWeb.API.OverseerJSON.state(Slipdock.Overseer.state(root))
       }}
    end
  end

  # Right now (#2103) names the cards of the whole tree, so it needs read on
  # the root too, as the overseer does.
  defp right_now(auth, board) do
    with {:ok, root} <- Args.refusal(SlipdockWeb.API.NowController.root(auth, board)) do
      {:ok,
       Map.merge(
         %{id: board.id, code: board.code, name: board.name},
         SlipdockWeb.API.NowJSON.snapshot(root.id, Slipdock.Now.snapshot(root))
       )}
    end
  end

  defp lists(auth, board) do
    board = Authorize.visible(auth, Boards.get_board!(board.id))
    roles = SlipdockWeb.APIGuide.list_roles(board.columns)
    # What in the tree waits on the caller (#2095).
    tree = Slipdock.Work.Tree.for_board(auth.assigns.current_user, board)

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
             cards:
               col.cards
               |> Enum.map(&Tools.card_line/1)
               |> SlipdockWeb.API.WaitingJSON.put_on_cards(tree, &(&1.subcards != nil))
           }
         end),
       waiting_on_me: SlipdockWeb.API.WaitingJSON.tree(tree)
     }
     |> Tools.ListBoards.put_lanes(board)
     |> Map.merge(SlipdockWeb.API.JSON.paused(board))}
  end

  defp role_of(roles, col) do
    Enum.find_value([:ready, :backlog, :doing, :done, :scheduled], fn role ->
      if roles[role] && roles[role].id == col.id, do: Atom.to_string(role)
    end)
  end
end
