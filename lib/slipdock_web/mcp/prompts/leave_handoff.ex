defmodule SlipdockWeb.MCP.Prompts.LeaveHandoff do
  @moduledoc """
  `leave-handoff`: write the card's handoff note (W-1804) from this
  conversation — the one next step and a short note — so whoever picks it
  up next starts from here.
  """
  @behaviour SlipdockWeb.MCP.Prompt

  alias SlipdockWeb.MCP.Prompts.Context

  @subcards 15

  @impl true
  def name, do: "leave-handoff"

  @impl true
  def title, do: "Leave a handoff"

  @impl true
  def description,
    do:
      "Writes the card's handoff note from this conversation: the one next step, and " <>
        "what is done, what bit, what is open, and where to look."

  @impl true
  def arguments,
    do: [%{name: "card", description: "The card to leave: 129 or #129.", required: true}]

  @impl true
  def writes?, do: true

  @impl true
  def tools, do: ["leave_handoff", "get_card"]

  @impl true
  def render(%{"card" => ref}, context) do
    with {:ok, card} <- Context.card(context, ref) do
      {:ok,
       """
       Leave a handoff on ##{card.id} #{card.title} (#{card.board.name}, list #{card.column.name}) \
       from what we did in this conversation.

       ## The handoff it has now (yours replaces it; it is kept as history)
       #{Context.handoff_text(card) || "None yet."}
       #{subcards(context, card)}
       Call leave_handoff with card #{card.id} and:
       - next_step: the one next step, one line (at most 280 characters).
       - body: a short Markdown note with State (what is done and half-done), Gotchas \
       (what bit), Open (questions waiting on someone) and Pointers (branch, files, \
       commits, pages).

       Write only what this conversation established; leave out a section rather than \
       guess. Show me the note before you save it.
       """}
    end
  end

  defp subcards(context, card) do
    case Context.open_subcards(context, card, @subcards) do
      nil -> ""
      lines -> "\n## Its open subcards\n#{lines}\n"
    end
  end
end
