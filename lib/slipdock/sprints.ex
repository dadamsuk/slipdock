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

  @doc "Whether `board` is a sprint board."
  def sprint_board?(%Board{} = board), do: Board.sprints?(board)
  def sprint_board?(_), do: false

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
