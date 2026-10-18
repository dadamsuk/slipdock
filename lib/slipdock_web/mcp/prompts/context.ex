defmodule SlipdockWeb.MCP.Prompts.Context do
  @moduledoc """
  The live board context prompts embed, read with the caller's token through
  the same access checks the tools use: a board-scoped token sees only its
  boards here too, and a stranger's board reads as not there.

  Everything here is plain text for the model to read, kept short: a long
  list is cut with `list/3`, which says how many it left out and which tool
  finds them.
  """

  alias Slipdock.{Access, Boards}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @doc "The boards' conventions, as the guide gives them: what every prompt starts from."
  def conventions do
    "Slipdock conventions: top-level cards are epics and the work is in their subcards. " <>
      "Take work from the top of a board's ready list; move a card to its doing list when " <>
      "you start it, comment as you go, and when it is finished mark it complete and move " <>
      "it to the done list. Cards are #id; wiki pages are W-n. The full conventions are " <>
      "in get_guide."
  end

  @doc "What a workflow that writes is told when the token can only read."
  def read_only_notice do
    "This connection's token is read-only. Don't try to change anything: report what " <>
      "you would do (each move, edit or comment, card by card) and stop there."
  end

  @doc "Every board the token can see, top level and not archived."
  def boards(%{user: user, token: token}), do: Access.list_boards(user, token: token)

  @doc """
  The board `ref` names (id, code or name), with its lists and their cards,
  if the token may read it; `{:error, message}` otherwise.
  """
  def board(context, ref) do
    auth = Args.auth(context)

    with {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :read)) do
      {:ok, Authorize.visible(auth, Boards.get_board!(board.id))}
    end
  end

  @doc "Which list plays which part on a loaded board: `%{ready:, backlog:, doing:, done:}`."
  def roles(board), do: SlipdockWeb.APIGuide.list_roles(board.columns)

  @doc "A board's lists with their open counts and parts, one line."
  def lists_line(board) do
    roles = roles(board)

    board.columns
    |> Enum.map_join(" · ", fn col ->
      part = Enum.find([:ready, :backlog, :doing, :done], &(roles[&1] && roles[&1].id == col.id))
      open = Enum.count(col.cards, &(not &1.completed))
      "#{col.name} (#{open} open#{if part, do: ", #{part}"})"
    end)
  end

  @doc "A board's heading: name, code and id."
  def board_heading(board), do: "#{board.name} (code #{board.code}, board ##{board.id})"

  @doc "One card, one line: number, title and what stands out about it."
  def card_line(card) do
    facts =
      [
        card.priority not in [nil, "none"] && "#{card.priority} priority",
        card.due_date && "due #{card.due_date}",
        card.flags != [] && "flagged #{Enum.join(card.flags, ", ")}",
        card.percent_complete && "#{card.percent_complete}%"
      ]
      |> Enum.filter(& &1)

    "##{card.id} #{card.title}" <> if(facts == [], do: "", else: " (#{Enum.join(facts, "; ")})")
  end

  @doc """
  `items` as `- ` lines, at most `max` of them. Past that it says how many
  more there are and `hint`, the tool that lists them all. `[]` reads `none`.
  """
  def list(items, max, hint) do
    {shown, rest} = Enum.split(items, max)

    case shown do
      [] ->
        "- none"

      _ ->
        lines = Enum.map_join(shown, "\n", &("- " <> &1))
        if rest == [], do: lines, else: lines <> "\n- …and #{length(rest)} more, use #{hint}"
    end
  end
end
