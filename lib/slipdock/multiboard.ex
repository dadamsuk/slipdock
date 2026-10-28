defmodule Slipdock.Multiboard do
  @moduledoc """
  The multiboard overview (#1479): the top N cards of lists chosen from any
  of the reader's boards, on one page, laid out by board, by list, or as a
  grid of tiles.

  A view is `%{lists: [column_id], top: n, by: layout}`. It is remembered on
  the user (`users.multiboard`) and carried in the URL, so one can be
  bookmarked. Lists come from the reader's top-level boards, archived boards
  left out; a list they can no longer read just drops out of the view.

  "Top" is the list's own order (`position`), as the board shows it, with
  archived and snoozed cards left out.
  """
  import Ecto.Query

  alias Slipdock.{Access, Accounts, Boards, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, Column}

  @layouts ~w(board list grid)
  @default_top 5
  @max_top 50

  @doc "The layouts a view can take: by board, by list, or a grid."
  def layouts, do: @layouts

  @doc "The most cards a view takes from each list."
  def max_top, do: @max_top

  @doc """
  The lists a reader can choose from: their top-level boards, in their own
  board order, each with its lists in board order. `:token` confines it to
  what an API token can reach.
  """
  def choices(user, opts \\ [])

  def choices(%User{} = user, opts) do
    boards =
      user
      |> Access.list_boards(token: opts[:token])
      |> Boards.sort_boards(user.board_sort || "manual")

    columns =
      from(c in Column,
        where: c.board_id in ^Enum.map(boards, & &1.id),
        order_by: [asc: c.position, asc: c.id]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.board_id)

    for board <- boards, do: %{board: board, columns: Map.get(columns, board.id, [])}
  end

  def choices(_, _opts), do: []

  @doc """
  A view from params as the page, the API and the CLI send them, anything
  missing taken from `saved` (the user's remembered view) and then the
  defaults. `lists` is a list or a comma-separated string of list ids;
  `top` is clamped to 1..#{@max_top}; an unknown `by` is `"board"`.
  """
  def normalize(params, saved \\ %{}) do
    params = params || %{}
    saved = saved || %{}
    pick = fn key -> Map.get(params, key, Map.get(saved, key)) end

    %{lists: ids(pick.("lists")), top: top(pick.("top")), by: by(pick.("by"))}
  end

  defp ids(nil), do: []
  defp ids(s) when is_binary(s), do: s |> String.split(",", trim: true) |> ids()

  defp ids(list) when is_list(list) do
    list
    |> Enum.map(fn
      n when is_integer(n) -> n
      s -> s |> to_string() |> String.trim() |> Integer.parse()
    end)
    |> Enum.flat_map(fn
      n when is_integer(n) and n > 0 -> [n]
      {n, ""} when n > 0 -> [n]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp ids(_), do: []

  defp top(n) when is_integer(n), do: n |> max(1) |> min(@max_top)

  defp top(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> top(n)
      _ -> @default_top
    end
  end

  defp top(_), do: @default_top

  defp by(b) when b in @layouts, do: b
  defp by(_), do: "board"

  @doc "The view this user last saved, normalized."
  def prefs(%User{multiboard: saved}), do: normalize(%{}, saved)

  @doc "Remembers a view as this user's own."
  def save_prefs(%User{} = user, %{lists: lists, top: top, by: by}) do
    Accounts.update_multiboard(user, %{"lists" => lists, "top" => top, "by" => by})
  end

  @doc """
  Resolves list references to ids against `choices/2`: an id, or
  `board/list` with the board's code (or name) and the list's name, case
  aside. Answers `{:ok, ids}` or `{:error, ref}` for the first it can't find.
  """
  def resolve(refs, choices) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case find(String.trim(ref), choices) do
        nil -> {:halt, {:error, ref}}
        id -> {:cont, {:ok, acc ++ [id]}}
      end
    end)
  end

  defp find(ref, choices) do
    case {Integer.parse(ref), String.split(ref, "/", parts: 2)} do
      {{id, ""}, _} ->
        if Enum.any?(choices, fn c -> Enum.any?(c.columns, &(&1.id == id)) end), do: id

      {_, [board, list]} ->
        Enum.find_value(choices, fn %{board: b, columns: cols} ->
          if same?(b.code, board) or same?(b.name, board),
            do: Enum.find_value(cols, &(same?(&1.name, list) && &1.id))
        end)

      _ ->
        nil
    end
  end

  defp same?(nil, _), do: false
  defp same?(a, b), do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  @doc """
  The view's lists with their top cards, in the reader's board order and
  then each board's list order (not the order they were picked in), as
  `%{board, column, cards}`. Lists not among `choices` are left out.
  """
  def entries(%{lists: ids, top: top}, choices) do
    chosen = MapSet.new(ids)

    picked =
      for %{board: board, columns: cols} <- choices,
          col <- cols,
          MapSet.member?(chosen, col.id),
          do: {board, col}

    cards = top_cards(Enum.map(picked, fn {_, col} -> col.id end), top)

    for {board, col} <- picked,
        do: %{board: board, column: col, cards: Map.get(cards, col.id, [])}
  end

  defp top_cards([], _top), do: %{}

  defp top_cards(column_ids, top) do
    ranked =
      from(c in Card,
        where: c.column_id in ^column_ids and is_nil(c.archived_at),
        select: %{
          id: c.id,
          rank:
            over(row_number(), partition_by: c.column_id, order_by: [asc: c.position, asc: c.id])
        }
      )
      |> Slipdock.Snooze.not_snoozed()

    from(c in Card,
      join: r in subquery(ranked),
      on: r.id == c.id,
      where: r.rank <= ^top,
      order_by: [asc: c.position, asc: c.id],
      preload: [:tags]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.column_id)
  end

  @doc """
  Entries laid out: `"board"` is a section per board with its lists' cards
  in turn, `"list"` a section per list, `"grid"` one section of every card.
  Each section is `%{key, label, board, items}`, and each item
  `%{card, board, column}` so a row or tile can say where it is from.
  """
  def group(entries, "list") do
    for %{board: b, column: col, cards: cards} <- entries do
      %{
        key: "list-#{col.id}",
        label: "#{b.name} › #{col.name}",
        board: b,
        items: items(b, col, cards)
      }
    end
  end

  def group(entries, "grid") do
    items = Enum.flat_map(entries, &items(&1.board, &1.column, &1.cards))
    if items == [], do: [], else: [%{key: "grid", label: nil, board: nil, items: items}]
  end

  def group(entries, _board) do
    entries
    |> Enum.chunk_by(& &1.board.id)
    |> Enum.map(fn [%{board: b} | _] = chunk ->
      %{
        key: "board-#{b.id}",
        label: b.name,
        board: b,
        items: Enum.flat_map(chunk, &items(b, &1.column, &1.cards))
      }
    end)
  end

  defp items(board, column, cards),
    do: Enum.map(cards, &%{card: &1, board: board, column: column})
end
