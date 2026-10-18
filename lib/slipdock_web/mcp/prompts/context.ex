defmodule SlipdockWeb.MCP.Prompts.Context do
  @moduledoc """
  The live board context prompts embed, read with the caller's token through
  the same access checks the tools use: a board-scoped token sees only its
  boards here too, and a stranger's board reads as not there.

  Everything here is plain text for the model to read, kept short: a long
  list is cut with `list/3`, which says how many it left out and which tool
  finds them.
  """

  import Ecto.Query

  alias Slipdock.{Access, Boards, Repo, Timezones, Work}
  alias Slipdock.Boards.{Activity, Board, Card}
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

  @doc "Today, in the person's own timezone."
  def today(%{user: user}), do: Timezones.today(Timezones.of(user))

  @doc """
  The board an optional `board` argument names: `{:ok, nil}` when there is
  none, else as `board/2`.
  """
  def maybe_board(_context, nil), do: {:ok, nil}
  def maybe_board(context, ref), do: board(context, ref)

  @doc """
  The ids of the root boards in play: the one board given, else every board
  the token sees.
  """
  def root_ids(_context, %Board{} = board), do: [Board.root_id(board)]
  def root_ids(context, nil), do: context |> boards() |> Enum.map(& &1.id)

  @doc """
  My work (`Slipdock.Work.assigned/3`): the cards assigned to the person,
  every level, narrowed to the token's boards and, given one, to that board's
  tree. Snoozed cards are not in it.
  """
  def my_work(%{user: user} = context, board) do
    roots = root_ids(context, board)

    user
    |> Work.assigned(nil, today: today(context), board_id: board && board.id)
    |> Enum.filter(&(Board.root_id(&1.card.board) in roots))
  end

  @doc "Whether a card sits on a list that is in progress."
  def doing?(%Card{column: %{} = column}),
    do: SlipdockWeb.APIGuide.role([column], column) == "doing"

  def doing?(_card), do: false

  @doc """
  Cards assigned to the person that are snoozed and wake before the end of
  today, in the roots given, readable by them.
  """
  def waking_today(%{user: user} = context, roots) do
    zone = Timezones.of(user)
    end_of_day = Timezones.to_utc(Date.add(today(context), 1), ~T[00:00:00], zone)

    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where: is_nil(c.archived_at) and not c.completed,
      where: coalesce(b.root_id, b.id) in ^roots,
      where:
        c.id in subquery(
          from(a in "card_assignees", where: a.user_id == ^user.id, select: a.card_id)
        ),
      where: c.snoozed_until < ^end_of_day,
      order_by: [asc: c.snoozed_until]
    )
    |> Slipdock.Snooze.only_snoozed()
    |> Repo.all()
    |> Repo.preload([:board, :column])
    |> then(&Access.filter_readable_cards(user, &1))
  end

  @doc """
  Every card that isn't archived in the trees of `roots`, sub-boards
  included, with its board and list, that the person may read.
  """
  def tree_cards(%{user: user}, roots) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where: is_nil(c.archived_at),
      where: coalesce(b.root_id, b.id) in ^roots,
      order_by: [asc: c.board_id, asc: c.position]
    )
    |> Repo.all()
    |> Repo.preload([:board, :column, :assignees])
    |> then(&Access.filter_readable_cards(user, &1))
  end

  @doc "The activity on the trees of `roots` since `since`, newest first, at most `limit`."
  def activity_since(roots, %DateTime{} = since, limit) do
    from(a in Activity,
      join: b in Board,
      on: b.id == a.board_id,
      where: coalesce(b.root_id, b.id) in ^roots and a.inserted_at >= ^since,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit,
      preload: [board: b]
    )
    |> Repo.all()
  end

  @doc "`path` from My work, as one string."
  def path_line(%{path: path}), do: Enum.join(path, " › ")
end
