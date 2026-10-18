defmodule SlipdockWeb.MCP.Prompts.Triage do
  @moduledoc """
  `triage`: the board's intake list (its Backlog or Inbox), card by card —
  keep, move, tag, date or archive — with the person deciding each one.
  """
  @behaviour SlipdockWeb.MCP.Prompt

  alias SlipdockWeb.MCP.Prompts.Context

  @cards 30
  @snippet 160

  @impl true
  def name, do: "triage"

  @impl true
  def title, do: "Triage the intake list"

  @impl true
  def description,
    do:
      "Walks a board's intake list (Backlog or Inbox) card by card: keep, move to the " <>
        "ready list, tag, date or archive, with you deciding each one."

  @impl true
  def arguments,
    do: [%{name: "board", description: "The board to triage (id, code or name).", required: true}]

  @impl true
  def writes?, do: true

  @impl true
  def tools, do: ["get_card", "move_card", "update_card", "archive_card", "comment", "list_cards"]

  @impl true
  def render(%{"board" => ref}, context) do
    with {:ok, board} <- Context.board(context, ref),
         {:ok, intake} <- intake(board) do
      roles = Context.roles(board)
      cards = Enum.reject(intake.cards, & &1.completed)

      {:ok,
       """
       Triage the #{intake.name} list on #{Context.board_heading(board)}: #{length(cards)} open card(s).

       Lists: #{Context.lists_line(board)}
       Ready list (where kept work goes): #{(roles.ready && roles.ready.name) || "none"}
       Tags on this board: #{tags(board)}

       ## #{intake.name}, top first
       #{cards |> Enum.map(&entry/1) |> Context.list(@cards, "list_cards")}

       Go through them one at a time, top first. For each, say in a line what it is and \
       suggest one of: keep it here, move it to the ready list (and where in it), tag it, \
       give it a due date or priority, or archive it. Wait for my answer, do exactly that, \
       and go on to the next. Stop when I say so or the list is done, then sum up what changed.
       """}
    end
  end

  defp intake(board) do
    case Context.roles(board).backlog do
      nil ->
        {:error,
         "#{board.name} has no intake list to triage: name a list Backlog or Inbox, " <>
           "or triage a board that has one"}

      list ->
        {:ok, list}
    end
  end

  defp tags(%{tags: tags}) when is_list(tags) and tags != [],
    do: Enum.map_join(tags, ", ", & &1.name)

  defp tags(_), do: "none"

  defp entry(card) do
    about =
      case card.description && String.trim(card.description) do
        nil -> ""
        "" -> ""
        text -> " — " <> (text |> String.replace(~r/\s+/, " ") |> String.slice(0, @snippet))
      end

    tagged = if card.tags == [], do: "", else: " [#{Enum.map_join(card.tags, ", ", & &1.name)}]"

    "#{Context.card_line(card)}#{tagged}, added #{Date.to_iso8601(DateTime.to_date(card.inserted_at))}#{about}"
  end
end
