defmodule SlipdockWeb.MCP.Prompts.TidyBoard do
  @moduledoc """
  `tidy-board`: the board gardener's suggestions (#1046, W-1807), walked one
  at a time with the person, each applied or dismissed with `garden_decide`
  only as they say.

  With a token and a board it can write, rendering looks the board over
  first (as `garden` with `run: true` does), so the list is fresh. That
  changes nothing on the board — a run only refreshes the suggestions — and
  a read-only token gets the suggestions as they stand.
  """
  @behaviour SlipdockWeb.MCP.Prompt

  alias Slipdock.{Access, Gardener}
  alias SlipdockWeb.API.GardenJSON, as: G
  alias SlipdockWeb.MCP.Prompts
  alias SlipdockWeb.MCP.Prompts.Context

  @suggestions 25
  @explanation 300

  @impl true
  def name, do: "tidy-board"

  @impl true
  def title, do: "Tidy up a board"

  @impl true
  def description,
    do:
      "Looks a board over with the gardener — done epics left open, stuck or stale cards, " <>
        "duplicates, orphaned pages — and walks the suggestions with you, one at a time."

  @impl true
  def arguments,
    do: [%{name: "board", description: "The board to tidy (id, code or name).", required: true}]

  @impl true
  def writes?, do: true

  @impl true
  def tools, do: ["garden", "garden_decide", "get_card", "read_page"]

  @impl true
  def render(%{"board" => ref}, context) do
    with {:ok, board} <- Context.board(context, ref) do
      ran? = writable?(context, board)
      if ran?, do: {:ok, _} = Gardener.run(board, trigger: "mcp", user: context.user)
      suggestions = G.suggestions(Gardener.list_open(board))

      {:ok,
       """
       Tidy up #{Context.board_heading(board)} with me.

       #{freshness(ran?, Gardener.last_run(board))}

       ## Open suggestions (#{length(suggestions)})
       #{suggestions |> Enum.map(&line/1) |> Context.list(@suggestions, "garden")}

       #{steps(suggestions)}
       """}
    end
  end

  defp writable?(context, board) do
    not Prompts.read_only?(context.token) and
      context.user |> Access.board_permission(board) |> Access.can_write?()
  end

  defp freshness(true, _run), do: "The gardener has just looked the board over."
  defp freshness(false, nil), do: "The gardener has never looked this board over."

  defp freshness(false, run),
    do:
      "As of the gardener's last look, #{Calendar.strftime(run.started_at, "%Y-%m-%d %H:%M")} UTC."

  defp steps([]),
    do:
      "Nothing to tidy: say so, and stop. Don't go looking for changes the gardener didn't suggest."

  defp steps(_),
    do:
      "Take them one at a time, in this order. For each, say in a line what it is and what " <>
        "applying it would do, then ask: apply, dismiss, or skip. Call garden_decide with what " <>
        "I chose (one marked needs_keep wants keep: the card that stays) and go on to the next. " <>
        "Change nothing I haven't approved, and sum up at the end."

  defp line(s) do
    things =
      Enum.map(s.cards, &"##{&1.id} #{&1.title}") ++
        Enum.map(s.pages, &"#{&1.code || "page #{&1.id}"} #{&1.title}")

    "suggestion #{s.id} · #{s.label || s.check}: #{Context.clip(s.explanation, @explanation)}" <>
      if(things == [], do: "", else: " (#{Enum.join(things, ", ")})") <>
      if(s.needs_keep, do: " [needs_keep]", else: "")
  end
end
