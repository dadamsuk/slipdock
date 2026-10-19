defmodule SlipdockWeb.MCP.Prompts.PlanMyDay do
  @moduledoc """
  `plan-my-day`: my work across boards — what is waiting on me first (#1118),
  then overdue, due today, in progress, the top of the ready lists and what wakes from a snooze today — and a short
  ordered plan for the day, agreed before anything moves.
  """
  @behaviour SlipdockWeb.MCP.Prompt

  alias SlipdockWeb.MCP.Prompts.Context

  # How much of each section is shown before "…and N more".
  @per_section 12
  @ready_per_board 3
  @ready_boards 8

  @impl true
  def name, do: "plan-my-day"

  @impl true
  def title, do: "Plan my day"

  @impl true
  def description,
    do:
      "My work right now — waiting on me, overdue, due today, in progress, the top of " <>
        "the ready lists — " <>
        "and a short plan for today. Asks before moving anything."

  @impl true
  def arguments,
    do: [
      %{
        name: "board",
        description: "Keep to one board (id, code or name). Left out, every board.",
        required: false
      }
    ]

  @impl true
  def writes?, do: true

  @impl true
  def tools, do: ["get_card", "list_cards", "move_card", "update_card", "comment"]

  @impl true
  def render(args, context) do
    with {:ok, board} <- Context.maybe_board(context, args["board"]) do
      today = Context.today(context)
      work = context |> Context.my_work(board) |> Enum.reject(&(&1.section == :done))
      roots = Context.root_ids(context, board)
      line = &"#{Context.card_line(&1.card)} — #{Context.path_line(&1)}"

      {:ok,
       """
       Help me plan my day. Today is #{Date.to_iso8601(today)} (#{Calendar.strftime(today, "%A")}). #{scope(board)}

       ## Waiting on you
       #{context |> Context.waiting_on_me(board) |> Enum.map(&Context.waiting_line/1) |> Context.list(@per_section, "slipdock work")}

       ## Overdue
       #{section(work, &(&1.section == :overdue), line)}

       ## Due today
       #{section(work, &(&1.section == :today), line)}

       ## In progress
       #{section(work, &(Context.doing?(&1.card) and &1.section not in [:overdue, :today]), line)}

       ## Waking from a snooze today
       #{context |> Context.waking_today(roots) |> Enum.map(&"#{Context.card_line(&1)} — #{&1.board.name}, wakes #{&1.snoozed_until}") |> Context.list(@per_section, "list_cards with snoozed: \"only\"")}

       ## Top of the ready lists (unassigned)
       #{ready(context, board)}

       Propose a short ordered plan for today: at most five items, the most pressing first, \
       with one line each on why. What is waiting on me comes first: a question I can answer \
       now (update_card answer_wait) unblocks someone else's work. Say what you would move to the doing list or reschedule, \
       then ask me before moving, assigning or editing anything, and do only what I agree to.
       """}
    end
  end

  defp scope(nil), do: "These are the cards assigned to me on every board I can see."
  defp scope(board), do: "These are the cards assigned to me on #{Context.board_heading(board)}."

  defp section(work, keep, line) do
    work |> Enum.filter(keep) |> Enum.map(line) |> Context.list(@per_section, "list_cards")
  end

  defp ready(context, board) do
    boards =
      case board do
        nil ->
          context
          |> Context.boards()
          |> Enum.take(@ready_boards)
          |> Enum.flat_map(&List.wrap(ok(Context.board(context, &1.id))))

        board ->
          [board]
      end

    boards
    |> Enum.map(fn b ->
      case Context.roles(b).ready do
        nil ->
          nil

        list ->
          cards =
            list.cards
            |> Enum.reject(&(&1.completed or &1.assignees != []))
            |> Enum.map(&Context.card_line/1)

          "#{Context.board_heading(b)}, #{list.name}:\n" <>
            Context.list(cards, @ready_per_board, "list_cards")
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "- none"
      blocks -> Enum.join(blocks, "\n")
    end
  end

  defp ok({:ok, value}), do: value
  defp ok(_), do: nil
end
