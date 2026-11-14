defmodule SlipdockWeb.MCP.Tools.GetBoard do
  @moduledoc "One board: its lists in order and the cards on each, briefly."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.{Args, Tools}

  # A done or dropped list shows this many of its cards, the newest done,
  # unless the call asks for them all (#3176).
  @done_shown 5

  @impl true
  def name, do: "get_board"

  @impl true
  def title, do: "Get a board"

  @impl true
  def description,
    do:
      "A board's lists with a brief of each card (no description: get_card); done lists " <>
        "only their newest #{@done_shown} unless include_done. Or instead: pulse, history, " <>
        "runners, dora, overseer, now."

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
        include_done: %{
          type: "boolean",
          description:
            "Every card in the done and dropped lists, not only the newest #{@done_shown}."
        },
        descriptions: %{
          type: "boolean",
          description: "Each card's description in its brief too (left out unless asked)."
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
        Enum.member?([true, "true"], args["dora"]) ->
          {:ok,
           board
           |> SlipdockWeb.API.JSON.dora(args["environment"], args["days"])
           |> Map.merge(%{name: board.name})}

        Enum.member?([true, "true"], args["history"]) ->
          {:ok,
           %{
             id: board.id,
             code: board.code,
             name: board.name,
             flow: Slipdock.Flow.history(board, days: args["days"])
           }}

        Enum.member?([true, "true"], args["runners"]) ->
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

        Enum.member?([true, "true"], args["pulse"]) ->
          {:ok,
           %{
             id: board.id,
             code: board.code,
             name: board.name,
             pulse: Slipdock.Pulse.for_board(board)
           }
           |> Map.merge(SlipdockWeb.API.JSON.paused(board))}

        true ->
          lists(auth, board, args)
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

  defp lists(auth, board, args) do
    with {:ok, all_done} <- Args.boolean(args, "include_done", false),
         {:ok, descriptions} <- Args.boolean(args, "descriptions", false),
         do: lists_of(auth, board, all_done: all_done, descriptions: descriptions)
  end

  defp lists_of(auth, board, opts) do
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
           {cards, left_out} = shown(board.columns, col, opts[:all_done])

           %{
             name: col.name,
             role: role_of(roles, col),
             wip_limit: col.wip_limit,
             cards:
               cards
               |> Enum.map(&Tools.card_brief(&1, opts))
               |> SlipdockWeb.API.WaitingJSON.put_on_cards(tree, &(&1[:subcards] != nil))
           }
           |> then(&if(left_out > 0, do: Map.put(&1, :left_out, left_out), else: &1))
         end),
       waiting_on_me: SlipdockWeb.API.WaitingJSON.tree(tree)
     }
     |> Map.merge(SlipdockWeb.API.JSON.paused(board))}
  end

  # A done or dropped list's newest done cards, and how many were left out.
  defp shown(columns, col, all_done) do
    if all_done or not done_list?(columns, col) do
      {col.cards, 0}
    else
      newest =
        col.cards
        |> Enum.sort_by(&(&1.completed_at || &1.updated_at), {:desc, DateTime})
        |> Enum.take(@done_shown)
        |> MapSet.new(& &1.id)

      # Kept in the list's own order.
      cards = Enum.filter(col.cards, &MapSet.member?(newest, &1.id))
      {cards, length(col.cards) - length(cards)}
    end
  end

  @doc "Whether `col` is a done or dropped list among `columns`."
  def done_list?(columns, col),
    do: Enum.member?(["done", "dropped"], SlipdockWeb.APIGuide.role(columns, col))

  defp role_of(roles, col) do
    Enum.find_value([:ready, :backlog, :doing, :done, :scheduled], fn role ->
      if roles[role] && roles[role].id == col.id, do: Atom.to_string(role)
    end)
  end
end
