defmodule SlipdockWeb.MCP.Prompts.WeeklyReview do
  @moduledoc """
  `weekly-review`: the last seven days told as a story — what was finished,
  what happened — and then what slipped and what has gone stale. Read-only.
  """
  @behaviour SlipdockWeb.MCP.Prompt

  alias SlipdockWeb.MCP.Prompts.Context

  @days 7
  # Shown, and read (so "…and N more" is a real count up to the second).
  @activity 60
  @activity_read 300
  @per_section 15

  @impl true
  def name, do: "weekly-review"

  @impl true
  def title, do: "Weekly review"

  @impl true
  def description,
    do:
      "The last 7 days as a short narrative — what got done and what happened — then " <>
        "what slipped and what is stale. Changes nothing."

  @impl true
  def arguments,
    do: [
      %{
        name: "board",
        description: "Review one board (id, code or name). Left out, every board.",
        required: false
      }
    ]

  @impl true
  def writes?, do: false

  @impl true
  def tools, do: ["activity", "list_cards", "get_card", "search"]

  @impl true
  def render(args, context) do
    with {:ok, board} <- Context.maybe_board(context, args["board"]) do
      today = Context.today(context)
      from = Date.add(today, -@days)
      since = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
      roots = Context.root_ids(context, board)
      cards = Context.tree_cards(context, roots)
      activity = Context.activity_since(roots, since, @activity_read)
      line = &"#{Context.card_line(&1)} — #{&1.board.name}"

      done =
        Enum.filter(
          cards,
          &((&1.completed and &1.completed_at) && DateTime.after?(&1.completed_at, since))
        )

      slipped =
        Enum.filter(
          cards,
          &((not &1.completed and &1.due_date) && Date.before?(&1.due_date, today))
        )

      stale =
        Enum.filter(cards, fn c ->
          not c.completed and Context.doing?(c) and
            DateTime.before?(c.updated_at, since)
        end)

      {:ok,
       """
       Write my weekly review: #{Date.to_iso8601(from)} to #{Date.to_iso8601(today)}, #{scope(board)}

       ## Finished this week (#{length(done)})
       #{done |> Enum.map(line) |> Context.list(@per_section, "list_cards")}

       ## What happened (newest first)
       #{activity |> Enum.map(&"#{Calendar.strftime(&1.inserted_at, "%a %d %b")} · #{&1.board.name}: #{&1.message}") |> Context.list(@activity, "activity")}

       ## Slipped: open and past due (#{length(slipped)})
       #{slipped |> Enum.sort_by(& &1.due_date, Date) |> Enum.map(line) |> Context.list(@per_section, "list_cards")}

       ## Stale: in progress, untouched for #{@days} days (#{length(stale)})
       #{stale |> Enum.map(line) |> Context.list(@per_section, "list_cards")}

       Tell it as a short narrative first: what moved, what got finished, what the week \
       was mostly about. Then list what slipped and what is stale, with a suggestion for \
       each (reschedule, hand back, break up, drop). This is a review: don't change \
       anything on the board.
       """}
    end
  end

  defp scope(nil), do: "every board I can see."
  defp scope(board), do: "on #{Context.board_heading(board)}."
end
