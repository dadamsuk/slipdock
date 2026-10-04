defmodule Slipdock.Sprints do
  @moduledoc """
  Sprints, made out of what a board already has.

  A sprint board is an ordinary board whose `kind` is `"sprints"` (the
  "Sprint planning" template makes one). Every card on it is a sprint: its
  start and due dates are the sprint's, and its subcards are the sprint's
  work. Nothing about a sprint is new except the two shortcuts here:

    * `create_sprint/2` — the next "Sprint N" card, dated to follow on from
      the last one, with its sub-board already made.
    * `add_cards/2` — pull cards from anywhere the person can write into a
      sprint, many at once, instead of moving them one by one. They are moved
      (`Slipdock.Boards.move_card_to_board/2`), so subcards, tags and fields
      travel the way they do on any move between boards.

  Pulling cards in is meant to be done a few at a time over days as well as
  all at once, so nothing here assumes a sprint is planned in one go.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Access
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Column, Template}
  alias Slipdock.Repo

  @default_days 14
  # The lists a new sprint's own board starts with, by template name; the
  # fallback is used only on a database that has lost that template.
  @sprint_template "Simple"
  @fallback_columns [
    %{"name" => "To Do", "category" => "todo"},
    %{"name" => "Doing", "color" => "sky", "category" => "doing"},
    %{"name" => "Done", "color" => "emerald", "category" => "done"}
  ]

  @doc "How long a sprint is unless told otherwise, in days."
  def default_days, do: @default_days

  @doc """
  Whether `card` is a sprint: a card sitting on a sprint board. `board` is
  the card's board when the caller already has it.
  """
  def sprint?(%Card{} = card, board \\ nil) do
    board = if match?(%Board{}, board) and board.id == card.board_id, do: board

    case board || Repo.get(Board, card.board_id) do
      %Board{} = board -> Board.sprints?(board)
      nil -> false
    end
  end

  @doc """
  The sprint a sprint's sub-board belongs to, or nil: what the sub-board's
  own toolbar offers Add cards… from.
  """
  def sprint_of_board(%Board{parent_card_id: nil}), do: nil

  def sprint_of_board(%Board{parent_card_id: card_id}) do
    card = Repo.get(Card, card_id)
    if card && sprint?(card), do: card
  end

  @doc """
  What `create_sprint/2` would make next on `board`: `%{name:, start:, days:}`.
  The name counts on from the highest "Sprint N" there; the start is the day
  after the last sprint ends, or today when there is none.
  """
  def next_sprint(%Board{} = board) do
    cards =
      Repo.all(
        from(c in Card,
          where: c.board_id == ^board.id,
          select: %{title: c.title, due: c.due_date, archived_at: c.archived_at}
        )
      )

    number =
      cards
      |> Enum.flat_map(fn %{title: title} ->
        case Regex.run(~r/^\s*sprint\s+(\d+)\b/i, title || "") do
          [_, n] -> [String.to_integer(n)]
          _ -> []
        end
      end)
      |> Enum.max(fn -> 0 end)

    last_due =
      cards
      |> Enum.filter(&(is_nil(&1.archived_at) and not is_nil(&1.due)))
      |> Enum.map(& &1.due)
      |> Enum.max(Date, fn -> nil end)

    start =
      case last_due do
        nil -> Date.utc_today()
        due -> Date.add(due, 1)
      end

    %{name: "Sprint #{number + 1}", start: start, days: @default_days}
  end

  @doc """
  Makes a sprint on `board`: a card in its first to-do list, dated, with a
  sub-board of its own for the work. `attrs` may carry `"name"`, `"start"`
  (a date or ISO string), `"days"` (its length) and `"goal"` (the card's
  description); anything missing comes from `next_sprint/1`.

  Returns `{:ok, card}` with the sub-board loaded, `{:error, message}`, or
  `{:error, changeset}` when the card itself was refused (see
  `error_message/1`).
  """
  def create_sprint(%Board{} = board, attrs \\ %{}, opts \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    next = next_sprint(board)

    with :ok <- check_sprint_board(board),
         {:ok, column} <- landing_column(Boards.get_board!(board.id)),
         {:ok, start} <- date(attrs["start"], next.start),
         {:ok, days} <- days(attrs["days"]) do
      name = blank(attrs["name"]) || next.name

      card_attrs = %{
        "title" => name,
        "description" => blank(attrs["goal"]),
        "start_date" => start,
        "due_date" => Date.add(start, days - 1)
      }

      with {:ok, card} <- Boards.create_card(column, card_attrs, opts),
           {:ok, _sub} <- Boards.create_sub_board(card, sprint_template()) do
        {:ok, Boards.get_card!(card.id)}
      else
        # A changeset goes back as it is: it may be the account's card limit,
        # which the API answers with its own 402 rather than a 422.
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, message} when is_binary(message) -> {:error, message}
      end
    end
  end

  defp check_sprint_board(board) do
    cond do
      Board.sub_board?(board) -> {:error, "Sprints go on a top-level sprint board."}
      not Board.sprints?(board) -> {:error, "#{board.name} is not a sprint board."}
      true -> :ok
    end
  end

  defp sprint_template do
    case Boards.find_template(@sprint_template) do
      {:ok, template} -> template
      _ -> %Template{name: "Sprint", columns: @fallback_columns}
    end
  end

  @doc """
  Moves `cards` into `sprint`'s sub-board, to its first to-do list. A sprint
  without a sub-board is given one first. Cards already in the sprint, cards
  that are the sprint or hold it, and archived cards are skipped rather than
  failing the lot.

  Returns `{:ok, %{added: [card], skipped: [{card, reason}]}}`, or
  `{:error, message}` when the sprint itself will not do.
  """
  def add_cards(%Card{} = sprint, cards) when is_list(cards) do
    with true <- sprint?(sprint) || {:error, "That card is not a sprint."},
         {:ok, board} <- sprint_board(sprint),
         {:ok, column} <- landing_column(board) do
      inside = MapSet.new(Boards.subtree_board_ids(sprint.id))

      {added, skipped} =
        cards
        |> Enum.uniq_by(& &1.id)
        |> Enum.reduce({[], []}, fn card, {added, skipped} ->
          card = Repo.get(Card, card.id)

          reason =
            cond do
              is_nil(card) -> "it no longer exists"
              card.id == sprint.id -> "it is the sprint"
              MapSet.member?(inside, card.board_id) -> "it is already in the sprint"
              not is_nil(card.archived_at) -> "it is archived"
              sprint?(card) -> "it is a sprint itself — pick from its cards instead"
              sprint.board_id in Boards.subtree_board_ids(card.id) -> "the sprint is inside it"
              true -> nil
            end

          if reason do
            {added, [{card, reason} | skipped]}
          else
            case Boards.move_card_to_board(card, column) do
              {:ok, %{card: moved}} ->
                {[moved | added], skipped}

              {:error, %Ecto.Changeset{} = refused} ->
                {added, [{card, refusal(refused)} | skipped]}

              {:error, message} ->
                {added, [{card, message} | skipped]}
            end
          end
        end)

      {:ok, %{added: Enum.reverse(added), skipped: Enum.reverse(skipped)}}
    end
  end

  defp refusal(changeset), do: Slipdock.Quota.refusal_message(changeset) || "it would not fit"

  defp sprint_board(%Card{} = sprint) do
    case Repo.one(from(b in Board, where: b.parent_card_id == ^sprint.id, select: b.id)) do
      nil ->
        case Boards.create_sub_board(sprint, sprint_template()) do
          {:ok, board} -> {:ok, Boards.get_board!(board.id)}
          {:error, message} -> {:error, message}
        end

      id ->
        {:ok, Boards.get_board!(id)}
    end
  end

  @doc """
  The list a card lands in on `board`: the first marked to-do, else the
  first that is not done or dropped, else the first.
  """
  def landing_column(%Board{columns: columns}) when is_list(columns) do
    open = Enum.reject(columns, &(Column.done?(&1) or Column.dropped?(&1)))

    case Enum.find(columns, &(&1.category == "todo")) || List.first(open) ||
           List.first(columns) do
      nil -> {:error, "That board has no lists."}
      column -> {:ok, column}
    end
  end

  ## Picking cards

  @doc """
  The boards `user` can take cards from for `sprint`: every top-level board
  they can write to, the sprint's own board included (its other sprints'
  leftovers are fair game), but not the sprint's own sub-board.
  """
  def source_boards(user, %Card{} = sprint) do
    own = Boards.subtree_board_ids(sprint.id)

    user
    |> Access.list_boards()
    |> Enum.filter(&(&1.id not in own and Access.can_write?(Access.board_permission(user, &1))))
  end

  @doc """
  What the picker shows of `board` for `sprint`: its lists, each with the
  open cards in it that could go into the sprint — not completed, not
  archived, not the sprint itself. A card with subcards carries
  `sub_board_id` so the picker can step into it. On a sprint board the cards
  are other sprints, there to step into for their leftovers rather than to
  be taken whole, so none is `pickable`.
  """
  def candidates(%Board{} = board, %Card{} = sprint) do
    board = Boards.get_board!(board.id)
    pickable = not Board.sprints?(board)
    inside = MapSet.new(Boards.subtree_board_ids(sprint.id))

    if MapSet.member?(inside, board.id) do
      []
    else
      Enum.map(board.columns, fn column ->
        cards =
          column.cards
          |> Enum.filter(&(is_nil(&1.archived_at) and not &1.completed and &1.id != sprint.id))
          |> Enum.map(fn card ->
            %{
              id: card.id,
              title: card.title,
              priority: card.priority,
              due_date: card.due_date,
              pickable: pickable,
              sub_board_id: sub_board_id(card)
            }
          end)

        %{id: column.id, name: column.name, color: column.color, cards: cards}
      end)
    end
  end

  defp sub_board_id(%Card{sub_board: %Board{id: id}}), do: id
  defp sub_board_id(_), do: nil

  ## Where sprints are planned from

  @doc """
  The boards and lists `board`'s sprints are planned from, as far as `user`
  can still take cards from them: `[%{board:, columns:, all:}]` in the order
  they were chosen. `all` is true when no lists were picked, and then
  `columns` is every list on the board that is not done or dropped. A board
  that has gone, been archived or is no longer the person's to write to
  drops out rather than failing the lot.
  """
  def sources(%Board{} = board, user) do
    board.sprint_sources
    |> List.wrap()
    |> Enum.flat_map(fn source ->
      with id when is_integer(id) <- source["board_id"],
           %Board{archived_at: nil} = from <- Repo.get(Board, id),
           true <- Access.can_write?(Access.board_permission(user, from)) do
        from = Repo.preload(from, :columns)
        chosen = List.wrap(source["column_ids"])

        columns =
          if chosen == [],
            do: open_columns(from.columns),
            else: Enum.filter(from.columns, &(&1.id in chosen))

        [%{board: from, columns: columns, all: chosen == []}]
      else
        _ -> []
      end
    end)
  end

  @doc """
  The boards `user` could plan `board`'s sprints from, with their lists:
  every top-level board they can write to except `board` itself and other
  sprint boards. `board` is nil for one not made yet.
  """
  def source_choices(user, board \\ nil) do
    own = board && Board.root_id(board)

    user
    |> Access.list_boards()
    |> Enum.filter(
      &(&1.id != own and not Board.sprints?(&1) and
          Access.can_write?(Access.board_permission(user, &1)))
    )
    |> Repo.preload(:columns)
  end

  @doc """
  The open lists of a board, by default what a source with no lists picked
  shows.
  """
  def default_columns(%Board{columns: columns}), do: open_columns(columns)

  defp open_columns(columns),
    do: Enum.reject(columns, &(Column.done?(&1) or Column.dropped?(&1)))

  @doc """
  Sets where `board`'s sprints are planned from. `sources` is a list of
  `{board, lists}`: a board (or its id) and the lists on it to show, by id
  or name, `[]` meaning every list that is not done or dropped. Each board
  has to be one `user` can write to, and not the sprint board or anything
  inside it; each list has to be on its board. `[]` clears them.

  Returns `{:ok, board}` or `{:error, message}`.
  """
  def put_sources(%Board{} = board, user, sources) when is_list(sources) do
    with :ok <- check_sprint_board(board),
         {:ok, stored} <- resolve_sources(board, user, sources) do
      board
      |> Ecto.Changeset.change(sprint_sources: stored)
      |> Repo.update()
      |> case do
        {:ok, board} ->
          Boards.broadcast_tree(board.id)
          {:ok, board}

        {:error, changeset} ->
          {:error, error_message(changeset)}
      end
    end
  end

  defp resolve_sources(board, user, sources) do
    sources
    |> Enum.uniq_by(fn {from, _} -> board_id(from) end)
    |> Enum.reduce_while({:ok, []}, fn {from, lists}, {:ok, acc} ->
      case resolve_source(board, user, from, List.wrap(lists)) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, stored} -> {:ok, Enum.reverse(stored)}
      error -> error
    end
  end

  defp resolve_source(board, user, from, lists) do
    from = if match?(%Board{}, from), do: from, else: Repo.get(Board, board_id(from) || 0)

    cond do
      is_nil(from) or not Access.can_write?(Access.board_permission(user, from)) ->
        {:error, "You can only plan sprints from boards you can write to."}

      Board.root_id(from) == Board.root_id(board) ->
        {:error, "A sprint board cannot plan its sprints from itself."}

      true ->
        columns = Repo.preload(from, :columns, force: true).columns

        Enum.reduce_while(lists, {:ok, []}, fn ref, {:ok, ids} ->
          case find_column(columns, ref) do
            nil -> {:halt, {:error, "#{from.name} has no list “#{ref}”."}}
            column -> {:cont, {:ok, ids ++ [column.id]}}
          end
        end)
        |> case do
          {:ok, ids} -> {:ok, %{"board_id" => from.id, "column_ids" => Enum.uniq(ids)}}
          error -> error
        end
    end
  end

  defp board_id(%Board{id: id}), do: id
  defp board_id(id) when is_integer(id), do: id

  defp board_id(text) when is_binary(text) do
    case Integer.parse(text) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp board_id(_), do: nil

  defp find_column(columns, ref) when is_integer(ref), do: Enum.find(columns, &(&1.id == ref))

  defp find_column(columns, ref) when is_binary(ref) do
    ref = String.trim(ref)

    case Integer.parse(ref) do
      {id, ""} -> find_column(columns, id)
      _ -> Enum.find(columns, &(String.downcase(&1.name) == String.downcase(ref)))
    end
  end

  defp find_column(_, _), do: nil

  ## Planning a sprint

  @plan_sorts [
    {"position", "Board order"},
    {"score", "Score"},
    {"priority", "Priority"},
    {"estimate", "Estimate"}
  ]

  @doc "The orders the planning view can put each list in, as `{value, label}`."
  def plan_sorts, do: @plan_sorts

  @doc """
  The planning view for `sprint`: every list `sources` names (see
  `sources/2`), with the open cards that could go into the sprint and what
  helps choose between them. Returns

      %{committed: %{cards:, estimate:},
        boards: [%{board:, all:, formulas: [field],
                   lists: [%{id:, name:, color:, cards: [entry]}]}]}

  where `committed` is what is in the sprint already, and each entry is
  `candidates/2`'s with `estimate` (minutes: the card's own, else what its
  open subcards add up to — `estimate_derived` says which), `unit`,
  `scores` (`[{field, value}]` for the board's formula fields), `votes`,
  `done`/`total` (its subcards, rolled up) and `ancestors` (empty here; see
  `plan_children/3`). Lists are put in `sort` order (see `plan_sorts/0`).
  """
  def plan(%Card{} = sprint, sources, sort \\ "position") when is_list(sources) do
    boards =
      Enum.map(sources, fn %{board: from, columns: columns, all: all} ->
        loaded = Boards.get_board!(from.id)
        wanted = MapSet.new(columns, & &1.id)

        lists =
          loaded
          |> plan_lists(sprint, [])
          |> Enum.filter(&MapSet.member?(wanted, &1.id))
          |> Enum.map(&%{&1 | cards: sort_entries(&1.cards, sort)})

        %{board: from, all: all, formulas: formulas(loaded), lists: lists}
      end)

    %{committed: committed(sprint), boards: boards}
  end

  @doc """
  What is in `sprint` already: `%{cards:, open:, estimate:}`, the estimate
  being the open cards' in minutes.
  """
  def committed(%Card{} = sprint) do
    work = Map.get(work_by_sprint([sprint.id]), sprint.id, [])
    open = Enum.reject(work, & &1.completed)

    %{
      cards: length(work),
      open: length(open),
      estimate: open |> Enum.map(&(&1.time_estimate || 0)) |> Enum.sum()
    }
  end

  @doc "The sprint board `sprint` sits on, where its sources are kept."
  def planning_board(%Card{board_id: id}), do: Repo.get(Board, id)

  @doc """
  A card's subcards in the planning view, every list of its sub-board in
  one, sorted by `sort`. `ancestors` is the path of card ids above them, so
  the view can tell a ticked card from one inside a ticked card.
  """
  def plan_children(sub_board_id, %Card{} = sprint, ancestors, sort \\ "position") do
    case Boards.get_board(sub_board_id) do
      nil ->
        []

      board ->
        board
        |> plan_lists(sprint, ancestors)
        |> Enum.flat_map(& &1.cards)
        |> sort_entries(sort)
    end
  end

  @doc """
  What a set of ticked cards adds up to: `%{cards:, estimate:}`, from
  `selected` (card id => `%{estimate:, ancestors:}`). Every ticked card
  counts as a card, but an estimate inside a ticked card is already in that
  card's, so it is not added twice.
  """
  def selection_totals(selected) when is_map(selected) do
    estimate =
      selected
      |> Map.values()
      |> Enum.reject(fn entry -> Enum.any?(entry.ancestors, &Map.has_key?(selected, &1)) end)
      |> Enum.map(&(&1.estimate || 0))
      |> Enum.sum()

    %{cards: map_size(selected), estimate: estimate}
  end

  defp plan_lists(%Board{} = board, sprint, ancestors) do
    formulas = formulas(board)
    pickable = not Board.sprints?(board)
    inside = MapSet.new(Boards.subtree_board_ids(sprint.id))

    if MapSet.member?(inside, board.id) do
      []
    else
      open =
        Enum.map(board.columns, fn column ->
          {column,
           Enum.filter(
             column.cards,
             &(is_nil(&1.archived_at) and not &1.completed and &1.id != sprint.id)
           )}
        end)

      estimates = estimates(Enum.flat_map(open, &elem(&1, 1)))

      Enum.map(open, fn {column, cards} ->
        entries =
          Enum.map(cards, fn card ->
            {estimate, derived} = Map.get(estimates, card.id, {card.time_estimate, false})
            stats = card.rollup || %{}

            %{
              id: card.id,
              title: card.title,
              priority: card.priority,
              due_date: card.due_date,
              pickable: pickable,
              sub_board_id: sub_board_id(card),
              position: card.position,
              estimate: estimate,
              estimate_derived: derived,
              unit: card.time_unit || "hours",
              scores: Enum.map(formulas, &{&1, Slipdock.Fields.numeric(card, &1)}),
              votes: Card.vote_total(card),
              done: Map.get(stats, :done, 0),
              total: Map.get(stats, :total, 0),
              children: Map.get(stats, :children, 0),
              ancestors: ancestors
            }
          end)

        %{id: column.id, name: column.name, color: column.color, cards: entries}
      end)
    end
  end

  defp formulas(%Board{} = board),
    do: (Map.get(board, :fields) || []) |> Enum.filter(&(&1.kind == "formula"))

  # The estimate of each card with subcards and none of its own: what its
  # open subcards' estimates add up to, each of those worked out the same way
  # (a card's own estimate wins over its children's). `{minutes, derived?}`
  # by card id; minutes is nil when nothing beneath is estimated.
  defp estimates(cards) do
    cards
    |> Enum.filter(&(is_nil(&1.time_estimate) and not is_nil(sub_board_id(&1))))
    |> Map.new(fn card ->
      boards = Boards.subtree_board_ids(card.id)

      children =
        from(c in Card,
          join: b in Board,
          on: b.id == c.board_id,
          where: c.board_id in ^boards and is_nil(c.archived_at) and not c.completed,
          select: {b.parent_card_id, c.id, c.time_estimate}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

      {card.id, {rolled_estimate(card.id, children), true}}
    end)
  end

  defp rolled_estimate(id, children) do
    children
    |> Map.get(id, [])
    |> Enum.map(fn {child, own} -> own || rolled_estimate(child, children) end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      minutes -> Enum.sum(minutes)
    end
  end

  @priority_rank %{"critical" => 0, "high" => 1, "medium" => 2, "low" => 3}

  # Highest first for score and priority, smallest first for estimate; cards
  # without one go last, and ties keep board order.
  defp sort_entries(entries, "score"), do: sort_by_key(entries, &first_score/1, :desc)

  defp sort_entries(entries, "priority"),
    do: sort_by_key(entries, &Map.get(@priority_rank, &1.priority), :asc)

  defp sort_entries(entries, "estimate"), do: sort_by_key(entries, & &1.estimate, :asc)
  defp sort_entries(entries, _), do: entries

  defp first_score(%{scores: [{_field, score} | _]}), do: score
  defp first_score(%{votes: votes}) when votes > 0, do: votes
  defp first_score(_), do: nil

  defp sort_by_key(entries, key, dir) do
    entries
    |> Enum.with_index()
    |> Enum.sort_by(fn {entry, i} ->
      case key.(entry) do
        nil -> {1, 0, i}
        n when dir == :desc -> {0, -n, i}
        n -> {0, n, i}
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  ## Charts

  @doc """
  A sprint's burndown: how much of its work was still open at the end of
  each day from its start to its due date. The work is the cards on the
  sprint's own board (not archived), counted as cards and, for those with an
  estimate, as estimated minutes. The scope is what is in the sprint now, so
  a card added late counts from the first day.

  Returns `%{sprint:, total:, done:, estimate:, days: [%{date:, remaining:,
  remaining_estimate:, ideal:}]}`; `remaining` is nil for days still to
  come. A sprint without dates runs #{@default_days} days from when it was made.
  """
  def burndown(%Card{} = sprint, today \\ Date.utc_today()) do
    work = Map.get(work_by_sprint([sprint.id]), sprint.id, [])
    {start, due} = sprint_dates(sprint)
    total = length(work)
    estimate = work |> Enum.map(&(&1.time_estimate || 0)) |> Enum.sum()
    span = Date.diff(due, start)

    days =
      Date.range(start, due)
      |> Enum.with_index()
      |> Enum.map(fn {date, i} ->
        open = if Date.compare(date, today) != :gt, do: open_on(work, date)

        %{
          date: date,
          remaining: open && length(open),
          remaining_estimate: open && open |> Enum.map(&(&1.time_estimate || 0)) |> Enum.sum(),
          ideal: if(span == 0, do: 0.0, else: total * (span - i) / span)
        }
      end)

    %{
      sprint: sprint_summary(sprint, start, due),
      total: total,
      done: Enum.count(work, & &1.completed),
      estimate: estimate,
      days: days
    }
  end

  @doc """
  Velocity on a sprint board: for each sprint, oldest first, the cards
  committed (everything in it now) and completed, and the same in estimated
  minutes. A sprint is `finished` once it is completed or past its due date;
  `average` is the cards completed per finished sprint, nil before the first.
  """
  def velocity(%Board{} = board, today \\ Date.utc_today()) do
    sprints =
      Repo.all(
        from(c in Card,
          where: c.board_id == ^board.id and is_nil(c.archived_at),
          order_by: [asc: c.position, asc: c.id]
        )
      )
      |> Enum.sort_by(fn card -> elem(sprint_dates(card), 0) end, Date)

    work = work_by_sprint(Enum.map(sprints, & &1.id))

    rows =
      Enum.map(sprints, fn sprint ->
        cards = Map.get(work, sprint.id, [])
        done = Enum.filter(cards, & &1.completed)
        {start, due} = sprint_dates(sprint)

        Map.merge(sprint_summary(sprint, start, due), %{
          committed: length(cards),
          completed: length(done),
          committed_estimate: cards |> Enum.map(&(&1.time_estimate || 0)) |> Enum.sum(),
          completed_estimate: done |> Enum.map(&(&1.time_estimate || 0)) |> Enum.sum(),
          finished: sprint.completed or Date.compare(due, today) == :lt
        })
      end)

    finished = Enum.filter(rows, & &1.finished)

    average =
      if finished != [],
        do: Float.round(Enum.sum(Enum.map(finished, & &1.completed)) / length(finished), 1)

    %{sprints: rows, average: average}
  end

  @doc """
  The sprint to chart first on a sprint board: the one running today, else
  the latest to have started, else the first. Nil on a board with none.
  """
  def current_sprint(%Board{} = board, today \\ Date.utc_today()) do
    sprints =
      Repo.all(from(c in Card, where: c.board_id == ^board.id and is_nil(c.archived_at)))
      |> Enum.sort_by(fn card -> elem(sprint_dates(card), 0) end, Date)

    Enum.find(sprints, fn card ->
      {start, due} = sprint_dates(card)
      Date.compare(start, today) != :gt and Date.compare(due, today) != :lt
    end) ||
      sprints
      |> Enum.filter(&(Date.compare(elem(sprint_dates(&1), 0), today) != :gt))
      |> List.last() ||
      List.first(sprints)
  end

  # Each sprint's work: the live cards on its own board, keyed by sprint id.
  defp work_by_sprint([]), do: %{}

  defp work_by_sprint(sprint_ids) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where: b.parent_card_id in ^sprint_ids and is_nil(c.archived_at),
      select: {b.parent_card_id, c}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The cards still open at the end of `date`. A card completed before
  # completed_at existed falls back to when it last changed.
  defp open_on(work, date) do
    Enum.reject(work, fn card ->
      card.completed and
        Date.compare(DateTime.to_date(card.completed_at || card.updated_at), date) != :gt
    end)
  end

  defp sprint_dates(%Card{} = sprint) do
    start = sprint.start_date || sprint.due_date || DateTime.to_date(sprint.inserted_at)
    due = sprint.due_date || Date.add(start, @default_days - 1)
    if Date.compare(start, due) == :gt, do: {due, due}, else: {start, due}
  end

  defp sprint_summary(sprint, start, due),
    do: %{id: sprint.id, title: sprint.title, start: start, due: due}

  ## Parsing

  defp date(nil, default), do: {:ok, default}
  defp date("", default), do: {:ok, default}
  defp date(%Date{} = date, _), do: {:ok, date}

  defp date(text, _) when is_binary(text) do
    case Date.from_iso8601(String.trim(text)) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "start must be a date, like 2026-10-05"}
    end
  end

  defp date(_, _), do: {:error, "start must be a date, like 2026-10-05"}

  defp days(nil), do: {:ok, @default_days}
  defp days(""), do: {:ok, @default_days}
  defp days(n) when is_integer(n) and n in 1..365, do: {:ok, n}

  defp days(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> days(n)
      _ -> {:error, "days must be a whole number from 1 to 365"}
    end
  end

  defp days(_), do: {:error, "days must be a whole number from 1 to 365"}

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(to_string(text)) do
      "" -> nil
      text -> text
    end
  end

  @doc "What went wrong, in a sentence, from either kind of error."
  def error_message(message) when is_binary(message), do: message

  def error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
