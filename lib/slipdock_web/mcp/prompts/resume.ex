defmodule SlipdockWeb.MCP.Prompts.Resume do
  @moduledoc """
  `resume`: pick a card back up from where it was left — its handoff note
  (#1043) first, then its open subcards, what blocks it and its latest
  comments — and say where things stand and the one next step.
  """
  @behaviour SlipdockWeb.MCP.Prompt

  alias SlipdockWeb.MCP.Prompts.Context

  @comments 8
  @comment_chars 600
  @subcards 25
  @description 2_000

  @impl true
  def name, do: "resume"

  @impl true
  def title, do: "Resume a card"

  @impl true
  def description,
    do:
      "Picks a card back up: reads its handoff note, open subcards and recent comments, " <>
        "then says where it stands and the next step."

  @impl true
  def arguments,
    do: [%{name: "card", description: "The card to resume: 129 or #129.", required: true}]

  @impl true
  def writes?, do: false

  @impl true
  def tools, do: ["get_card", "list_cards", "activity", "read_page"]

  @impl true
  def render(%{"card" => ref}, context) do
    with {:ok, card} <- Context.card(context, ref) do
      {:ok,
       """
       Help me pick up ##{card.id} #{card.title} where it was left.

       Card: #{Context.card_line(card)} — #{card.board.name}, list #{card.column.name}#{if card.completed, do: ", completed", else: ""}
       Assigned: #{assigned(card)}
       Blocked by: #{blocked_by(card)}

       ## Handoff (where it was left)
       #{Context.handoff_text(card) || "No handoff note: work it out from the comments below."}

       ## Description
       #{case Context.clip(card.description, @description) do
         "" -> "(none)"
         text -> text
       end}
       #{subcards(context, card)}
       ## Latest comments (newest first)
       #{card.comments |> newest_first() |> Enum.map(&comment/1) |> Context.list(@comments, "get_card")}

       Say in a few lines where this stands: what is done, what is half-done, what it is \
       waiting on. Then give the one next step, starting from the handoff's when there is \
       one. Read more with get_card if you need it, but don't change anything yet.
       """}
    end
  end

  defp assigned(%{assignees: [_ | _] = people}),
    do: Enum.map_join(people, ", ", &(&1.name || &1.email))

  defp assigned(_), do: "nobody"

  defp blocked_by(%{blocked_by: [_ | _] = cards}),
    do: Enum.map_join(cards, ", ", &"##{&1.id} #{&1.title}#{if &1.completed, do: " (done)"}")

  defp blocked_by(_), do: "nothing"

  defp subcards(context, card) do
    case Context.open_subcards(context, card, @subcards) do
      nil -> ""
      lines -> "\n## Open subcards\n#{lines}\n"
    end
  end

  # Two comments in the same second still come newest first.
  defp newest_first(comments),
    do: Enum.sort_by(comments, &{DateTime.to_unix(&1.inserted_at), &1.id}, :desc)

  defp comment(c) do
    who = if match?(%{name: _}, c.user), do: c.user.name || c.user.email, else: "someone"

    "#{Calendar.strftime(c.inserted_at, "%Y-%m-%d")} #{who}: #{Context.clip(c.body, @comment_chars)}"
  end
end
