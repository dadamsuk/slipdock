defmodule Slipdock.Swimlanes do
  @moduledoc """
  Turns a board's cards into a swimlane grid according to a
  `Slipdock.Swimlanes.Config`: filtering, bucketing cards on two axes
  (including date bucketing by day/week/month/quarter/year), sorting inside
  each cell, and working out the attribute changes implied by dragging a card
  from one cell to another.

  Everything here is pure; persistence lives in `Slipdock.Boards`.
  """

  alias Slipdock.Boards.Card
  alias Slipdock.Palette
  alias Slipdock.Swimlanes.Config

  @priority_rank %{"none" => 0, "low" => 1, "medium" => 2, "high" => 3, "critical" => 4}
  @priority_order ~w(critical high medium low none)
  @priority_labels %{
    "none" => "No priority",
    "low" => "Low",
    "medium" => "Medium",
    "high" => "High",
    "critical" => "Critical"
  }
  @flag_labels [
    {"flagged", "Flagged"},
    {"blocked", "Blocked"},
    {"review", "Needs review"},
    {"waiting", "Waiting"},
    {"starred", "Starred"}
  ]
  @max_gap_fill 120

  @type bucket :: %{key: String.t(), label: String.t(), color: String.t() | nil, tone: atom | nil}

  ## Grid ---------------------------------------------------------------------

  @doc """
  Builds the grid for `board` (as loaded by `Slipdock.Boards.get_board!/1`).

  Returns `%{rows: [...], cols: [...], shown: n, hidden: n}` where each row is
  a bucket map with `:count` and `:cells` (a list of sorted card lists, one per
  column bucket), and each column is a bucket map with `:count`.
  """
  def grid(board, %Config{} = config, today \\ Date.utc_today()) do
    col_pos = Map.new(board.columns, &{&1.id, &1.position})
    # Wiki pages placed on the board are card-shaped and stand beside the
    # cards in every view (see `Slipdock.Wiki.Page`).
    all = Enum.flat_map(board.columns, &(&1.cards ++ placed_pages(&1)))
    cards = Enum.filter(all, &matches?(&1, config, today))

    cells =
      Enum.reduce(cards, %{}, fn card, acc ->
        for rk <- card_keys(card, config.rows, config.unit),
            ck <- card_keys(card, config.cols, config.unit),
            reduce: acc do
          acc -> Map.update(acc, {rk, ck}, [card], &[card | &1])
        end
      end)

    rows = buckets(config.rows, board, cards, config, today)
    cols = buckets(config.cols, board, cards, config, today)

    row_count = fn rk ->
      cells
      |> Enum.filter(fn {{r, _}, _} -> r == rk end)
      |> Enum.map(fn {_, cs} -> length(cs) end)
      |> Enum.sum()
    end

    col_count = fn ck ->
      cells
      |> Enum.filter(fn {{_, c}, _} -> c == ck end)
      |> Enum.map(fn {_, cs} -> length(cs) end)
      |> Enum.sum()
    end

    rows = Enum.map(rows, &Map.put(&1, :count, row_count.(&1.key)))
    cols = Enum.map(cols, &Map.put(&1, :count, col_count.(&1.key)))

    {rows, cols} =
      if config.empty == "hide" do
        {Enum.reject(rows, &(&1.count == 0)), Enum.reject(cols, &(&1.count == 0))}
      else
        {rows, cols}
      end

    rows =
      Enum.map(rows, fn row ->
        Map.put(
          row,
          :cells,
          Enum.map(cols, fn col ->
            sort(Map.get(cells, {row.key, col.key}, []), config, col_pos)
          end)
        )
      end)

    %{rows: rows, cols: cols, shown: length(cards), hidden: length(all) - length(cards)}
  end

  @doc "The wiki pages placed in a list, when the board was loaded with them."
  def placed_pages(%{pages: pages}) when is_list(pages), do: pages
  def placed_pages(_), do: []

  ## Filtering ---------------------------------------------------------------

  @doc """
  Whether `card` passes the filters in `config` — a wiki page placed on the
  board too, since it carries the same facets, and `kinds` is the filter that
  tells the two apart (see `Slipdock.Kinds`).
  """
  def matches?(card, %Config{} = config, today \\ Date.utc_today()) do
    q = String.downcase(config.q)

    (q == "" or
       String.contains?(String.downcase(card.title), q) or
       String.contains?(String.downcase(card.description || ""), q) or
       Enum.any?(card.tags, &String.contains?(String.downcase(&1.name), q))) and
      Slipdock.Kinds.matches?(card, config.kinds) and
      (config.tags == [] or Enum.any?(card.tags, &(&1.id in config.tags))) and
      (config.priorities == [] or card.priority in config.priorities) and
      (config.flags == [] or Enum.any?(card.flags, &(&1 in config.flags))) and
      (config.columns == [] or card.column_id in config.columns) and
      (config.colors == [] or (card.color || "none") in config.colors) and
      due_matches?(config.due, card, today) and
      done_matches?(config.done, card) and
      deps_matches?(config.deps, card)
  end

  @doc """
  Whether `card` passes one of `Slipdock.Swimlanes.Config.deps/0`'s buckets:
  `"blocked"`, `"ready"`, `"blocking"`, `"violated"` or `"free"`. `nil` means
  no filter. Needs `blocked_by` and `blocks` preloaded.

  Public because the same vocabulary filters cards outside a view —
  `Slipdock.Boards.list_cards/2`, and through it the API, the CLI and the
  assistant — and one definition of "blocked" is worth having.
  """
  def deps_matches?(nil, _), do: true
  def deps_matches?("blocked", card), do: Card.blocked?(card)
  def deps_matches?("ready", card), do: not Card.blocked?(card)
  def deps_matches?("blocking", card), do: card.blocks != []
  def deps_matches?("violated", card), do: Card.violated_blockers(card) != []
  def deps_matches?("free", card), do: card.blocks == [] and card.blocked_by == []

  @doc """
  Whether `card` falls in one of `Slipdock.Swimlanes.Config.dues/0`'s buckets:
  `"overdue"`, `"today"`, `"week"` (the next 7 days), `"month"` (the next 30),
  `"has"` or `"none"`. `nil` means no filter.

  A completed card is in none of the date buckets — "overdue" means still
  outstanding — though it can still have or lack a date. Public for the same
  reason as `deps_matches?/2`.
  """
  def due_matches?(bucket, card, today \\ Date.utc_today())
  def due_matches?(nil, _, _), do: true
  def due_matches?("none", card, _), do: is_nil(card.due_date)
  def due_matches?("has", card, _), do: not is_nil(card.due_date)
  def due_matches?(_, %{due_date: nil}, _), do: false
  def due_matches?(_, %{completed: true}, _), do: false
  def due_matches?("overdue", card, today), do: Date.compare(card.due_date, today) == :lt
  def due_matches?("today", card, today), do: Date.compare(card.due_date, today) == :eq
  def due_matches?("week", card, today), do: Date.diff(card.due_date, today) in 0..7
  def due_matches?("month", card, today), do: Date.diff(card.due_date, today) in 0..30

  defp done_matches?("all", _), do: true
  defp done_matches?("hide", card), do: not card.completed
  defp done_matches?("only", card), do: card.completed

  ## Sorting -----------------------------------------------------------------

  @doc """
  Sorts a list of cards by the config's sort field and direction. Ties keep
  board order (list position, then card position); cards without a value for
  the sort field (e.g. no due date) always go last. Sorting by start date puts
  cards without one at their due date, so it is the order they are scheduled.
  """
  def sort(cards, %Config{sort: sort, dir: dir}, col_pos \\ %{}) do
    cards = Enum.sort_by(cards, &{Map.get(col_pos, &1.column_id, 0), list_position(&1)})

    case sort do
      "position" ->
        if dir == "desc", do: Enum.reverse(cards), else: cards

      _ ->
        {with_value, without} = Enum.split_with(cards, &(not is_nil(sort_key(&1, sort))))
        sorter = if dir == "desc", do: :desc, else: :asc
        Enum.sort_by(with_value, &sort_key(&1, sort), sorter) ++ without
    end
  end

  # Where something sits in its list. A card's `position` is that; a wiki page
  # placed on the board keeps its `position` for the wiki tree and orders
  # itself on the board with `board_position` (see `Slipdock.Wiki.Page`).
  defp list_position(%{board_position: n}) when is_integer(n), do: n
  defp list_position(%{position: n}), do: n
  defp list_position(_), do: 0

  defp sort_key(card, "title"), do: String.downcase(card.title)
  defp sort_key(card, "priority"), do: @priority_rank[card.priority]
  defp sort_key(%{due_date: nil}, "due_date"), do: nil
  defp sort_key(card, "due_date"), do: Date.to_iso8601(card.due_date)

  # Schedule order: a card without a start date starts when it is due.
  defp sort_key(card, "start_date") do
    case Card.starts_on(card) do
      nil -> nil
      date -> {Date.to_iso8601(date), Date.to_iso8601(Card.ends_on(card))}
    end
  end

  defp sort_key(card, "percent_complete"), do: card.percent_complete
  defp sort_key(card, "created"), do: DateTime.to_iso8601(card.inserted_at)
  defp sort_key(card, "updated"), do: DateTime.to_iso8601(card.updated_at)
  defp sort_key(card, "votes"), do: Card.vote_total(card)

  # A custom field: a formula's computed value, else the stored value
  # (numbers sort as numbers, everything else as text).
  defp sort_key(card, "f:" <> _ = key) do
    case field_value(card, key) do
      nil -> nil
      n when is_number(n) -> n
      %Date{} = d -> Date.to_iso8601(d)
      other -> String.downcase(to_string(other))
    end
  end

  @doc "A card's raw value for a `f:<id>` key, without the field definition."
  def field_value(card, key) do
    id = Config.custom_id(key)

    case Map.get(card.computed || %{}, id) do
      nil ->
        case Enum.find(card.field_values || [], &(&1.field_id == id)) do
          nil -> nil
          v -> Slipdock.Boards.FieldValue.get(v)
        end

      computed ->
        computed
    end
  end

  ## Buckets -----------------------------------------------------------------

  @doc "The bucket keys a card belongs to on `axis` (a list, since tags and flags are multi-valued)."
  def card_keys(card, axis, unit)
  def card_keys(_card, "none", _), do: ["all"]
  def card_keys(card, "column", _), do: [to_string(card.column_id)]
  # A card with several people on it sits in each of their lanes.
  def card_keys(card, "assignee", _) do
    case Card.assignees(card) do
      [] -> if card.assignee_id, do: [to_string(card.assignee_id)], else: ["none"]
      people -> Enum.map(people, &to_string(&1.id))
    end
  end

  def card_keys(card, "priority", _), do: [card.priority]
  def card_keys(%{tags: []}, "tag", _), do: ["none"]
  def card_keys(card, "tag", _), do: Enum.map(card.tags, &to_string(&1.id))
  def card_keys(%{flags: []}, "flag", _), do: ["none"]
  def card_keys(card, "flag", _), do: card.flags
  def card_keys(card, "completed", _), do: [if(card.completed, do: "done", else: "open")]
  def card_keys(card, "color", _), do: [card.color || "none"]
  def card_keys(card, "due_date", unit), do: [date_key(card.due_date, unit)]
  # The rolled-up due date: the card's own, else its subcards' latest.
  def card_keys(card, "schedule", unit), do: [date_key(Card.effective_due(card), unit)]
  def card_keys(card, "created", unit), do: [date_key(DateTime.to_date(card.inserted_at), unit)]
  def card_keys(card, "updated", unit), do: [date_key(DateTime.to_date(card.updated_at), unit)]

  def card_keys(card, "f:" <> _ = key, _) do
    case field_value(card, key) do
      nil -> ["none"]
      n when is_number(n) -> [number_key(n)]
      other -> [to_string(other)]
    end
  end

  def card_keys(card, "goal", _) do
    case Card.goals(card) do
      [] -> ["none"]
      goals -> Enum.map(goals, &to_string(&1.id))
    end
  end

  def card_keys(card, "dependencies", _) do
    keys =
      Enum.reject(
        [if(Card.blocked?(card), do: "blocked"), if(card.blocks != [], do: "blocking")],
        &is_nil/1
      )

    if keys == [], do: ["free"], else: keys
  end

  @doc "The ordered buckets for `axis`, given the (already filtered) cards."
  def buckets(axis, board, cards, config, today \\ Date.utc_today())

  def buckets("none", _board, _cards, _config, _today),
    do: [bucket("all", "All cards")]

  def buckets("column", board, _cards, _config, _today),
    do: Enum.map(board.columns, &bucket(to_string(&1.id), &1.name, &1.color))

  def buckets("assignee", _board, cards, _config, _today) do
    users =
      cards
      |> Enum.flat_map(&Card.assignees/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&String.downcase(Slipdock.Accounts.User.display_name(&1)))

    Enum.map(users, &bucket(to_string(&1.id), Slipdock.Accounts.User.display_name(&1))) ++
      [bucket("none", "Unassigned")]
  end

  def buckets("priority", _board, _cards, _config, _today),
    do: Enum.map(@priority_order, &bucket(&1, @priority_labels[&1]))

  def buckets("tag", board, _cards, _config, _today),
    do:
      Enum.map(board.tags, &bucket(to_string(&1.id), &1.name, &1.color)) ++
        [bucket("none", "No tag")]

  def buckets("flag", _board, _cards, _config, _today),
    do: Enum.map(@flag_labels, fn {k, l} -> bucket(k, l) end) ++ [bucket("none", "No flag")]

  def buckets("completed", _board, _cards, _config, _today),
    do: [bucket("open", "Open"), bucket("done", "Completed")]

  def buckets("color", _board, _cards, _config, _today),
    do: Enum.map(Palette.all(), fn {n, l} -> bucket(n, l, n) end) ++ [bucket("none", "No cover")]

  def buckets("goal", _board, cards, _config, _today) do
    goals =
      cards
      |> Enum.flat_map(&Card.goals/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&String.downcase(&1.title))

    Enum.map(goals, &bucket(to_string(&1.id), &1.title)) ++ [bucket("none", "No goal")]
  end

  def buckets("dependencies", _board, _cards, _config, _today),
    do: [
      bucket("blocked", "Blocked"),
      bucket("blocking", "Blocks others"),
      bucket("free", "No dependencies")
    ]

  def buckets("f:" <> _ = key, board, cards, _config, _today) do
    case Config.custom_field(key, board) do
      %{kind: "rating"} = field ->
        max = Slipdock.Boards.FieldDefinition.rating_max(field)

        Enum.map(max..1//-1, &bucket(number_key(&1 * 1.0), String.duplicate("★", &1))) ++
          [bucket("none", "Not rated")]

      %{kind: "select"} = field ->
        Enum.map(field.options, &bucket(&1["key"], &1["label"], &1["color"])) ++
          [bucket("none", "No #{String.downcase(field.name)}")]

      %{} = field ->
        keys = cards |> Enum.flat_map(&card_keys(&1, key, nil)) |> Enum.uniq()
        {valued, none} = Enum.split_with(keys, &(&1 != "none"))

        Enum.map(Enum.sort(valued), &bucket(&1, Slipdock.Fields.format(field, parse_key(&1)))) ++
          Enum.map(none, fn _ -> bucket("none", "No #{String.downcase(field.name)}") end)

      nil ->
        [bucket("none", "Unknown field")]
    end
  end

  def buckets(axis, _board, cards, %Config{unit: unit} = config, today)
      when axis in ~w(due_date schedule created updated) do
    keys =
      cards
      |> Enum.flat_map(&card_keys(&1, axis, unit))
      |> Enum.uniq()

    {dated, none} = Enum.split_with(keys, &(&1 != "none"))
    dated = Enum.sort(dated)
    dated = if config.empty == "show", do: fill_gaps(dated, unit), else: dated
    today_key = date_key(today, unit)

    Enum.map(dated, fn key ->
      tone =
        cond do
          key == today_key -> :current
          axis in ~w(due_date schedule) and key < today_key -> :past
          true -> nil
        end

      bucket(key, date_label(key, unit, today), nil, tone)
    end) ++ Enum.map(none, fn _ -> bucket("none", "No due date") end)
  end

  defp bucket(key, label, color \\ nil, tone \\ nil),
    do: %{key: key, label: label, color: color, tone: tone}

  # Numeric bucket keys: whole numbers without a decimal point, so ratings
  # read as "3" and formulas keep two decimals.
  defp number_key(n) when is_float(n) and n == trunc(n), do: Integer.to_string(trunc(n))
  defp number_key(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp number_key(n) when is_integer(n), do: Integer.to_string(n)

  defp parse_key(key) do
    case Float.parse(key) do
      {f, ""} -> f
      _ -> key
    end
  end

  defp fill_gaps([], _unit), do: []

  defp fill_gaps([first | _] = keys, unit) do
    last = List.last(keys)

    filled =
      Stream.iterate(first, &next_key(&1, unit))
      |> Enum.take_while(&(&1 <= last))
      |> Enum.take(@max_gap_fill)

    if List.last(filled) == last, do: filled, else: keys
  end

  ## Dates -------------------------------------------------------------------

  @doc "The bucket key (ISO date of the bucket start) for a date at the given unit."
  def date_key(nil, _unit), do: "none"
  def date_key(%Date{} = d, "day"), do: Date.to_iso8601(d)
  def date_key(%Date{} = d, "week"), do: Date.to_iso8601(Date.beginning_of_week(d))
  def date_key(%Date{} = d, "month"), do: Date.to_iso8601(Date.beginning_of_month(d))

  def date_key(%Date{} = d, "quarter"),
    do: Date.to_iso8601(Date.new!(d.year, div(d.month - 1, 3) * 3 + 1, 1))

  def date_key(%Date{} = d, "year"), do: Date.to_iso8601(Date.new!(d.year, 1, 1))

  @doc "The first date in the bucket identified by `key`."
  def bucket_start("none"), do: nil
  def bucket_start(key), do: Date.from_iso8601!(key)

  defp next_key(key, unit) do
    start = bucket_start(key)

    shifted =
      case unit do
        "day" -> Date.shift(start, day: 1)
        "week" -> Date.shift(start, week: 1)
        "month" -> Date.shift(start, month: 1)
        "quarter" -> Date.shift(start, month: 3)
        "year" -> Date.shift(start, year: 1)
      end

    Date.to_iso8601(shifted)
  end

  @doc "A human label for a date bucket."
  def date_label(key, unit, today \\ Date.utc_today())
  def date_label("none", _, _), do: "No date"

  def date_label(key, unit, today) do
    start = bucket_start(key)
    year = if start.year == today.year, do: "", else: " #{start.year}"

    case unit do
      "day" ->
        Calendar.strftime(start, "%a %-d %b") <> year

      "week" ->
        finish = Date.add(start, 6)

        if start.month == finish.month,
          do: "#{start.day}–#{Calendar.strftime(finish, "%-d %b")}" <> year,
          else:
            "#{Calendar.strftime(start, "%-d %b")} – #{Calendar.strftime(finish, "%-d %b")}" <>
              year

      "month" ->
        Calendar.strftime(start, "%b %Y")

      "quarter" ->
        "Q#{div(start.month - 1, 3) + 1} #{start.year}"

      "year" ->
        Integer.to_string(start.year)
    end
  end

  ## Moves -------------------------------------------------------------------

  @typedoc """
  An operation to apply to a card so it lands in a bucket:
    * `{:column, id}` – move to the list with that id
    * `{:attrs, map}` – update the given card attributes
    * `{:tags, [tag_id]}` – replace the card's tags
    * `{:field, field_id, raw}` – set a custom field (nil clears it)
    * `{:error, message}` – the move is impossible on this axis
  """
  @type op ::
          {:column, integer}
          | {:attrs, map}
          | {:tags, [integer]}
          | {:field, integer, String.t() | nil}
          | {:error, String.t()}

  @doc """
  The operations needed to move `card` from bucket `from_key` to `to_key`
  on `axis`. `from_key` may be nil when the card is new.
  """
  @spec move_ops(String.t(), Card.t() | nil, String.t() | nil, String.t(), Config.t()) :: [op]
  def move_ops(axis, card, from_key, to_key, config)

  def move_ops(_axis, _card, same, same, _config), do: []
  def move_ops("none", _card, _from, _to, _config), do: []
  def move_ops("column", _card, _from, to, _config), do: [{:column, String.to_integer(to)}]
  def move_ops("priority", _card, _from, to, _config), do: [{:attrs, %{"priority" => to}}]

  def move_ops("completed", _card, _from, to, _config),
    do: [{:attrs, %{"completed" => to == "done"}}]

  def move_ops("color", _card, _from, "none", _config), do: [{:attrs, %{"color" => nil}}]
  def move_ops("color", _card, _from, to, _config), do: [{:attrs, %{"color" => to}}]

  def move_ops("tag", card, from, to, _config) do
    ids = card |> current_tag_ids() |> List.delete(parse_int(from))
    ids = if int = parse_int(to), do: Enum.uniq(ids ++ [int]), else: ids
    [{:tags, ids}]
  end

  def move_ops("flag", card, from, to, _config) do
    flags = (card && card.flags) || []
    flags = if from in Card.flags(), do: List.delete(flags, from), else: flags
    flags = if to in Card.flags(), do: Enum.uniq(flags ++ [to]), else: flags
    [{:attrs, %{"flags" => flags}}]
  end

  # Between two people's lanes the card changes hands — the one it came from
  # comes off it, the one it went to goes on, and anybody else on it stays.
  # Dropped on "Unassigned" it is nobody's.
  def move_ops("assignee", _card, _from, "none", _config),
    do: [{:attrs, %{"assignee_ids" => []}}]

  def move_ops("assignee", card, from, to, _config) do
    ids = card |> Card.assignees() |> Enum.map(& &1.id)
    to = String.to_integer(to)

    ids =
      case Enum.find_index(ids, &(&1 == parse_int(from))) do
        nil -> ids ++ [to]
        i -> List.replace_at(ids, i, to)
      end

    [{:attrs, %{"assignee_ids" => Enum.uniq(ids)}}]
  end

  def move_ops(axis, _card, _from, "none", _config) when axis in ~w(due_date schedule),
    do: [{:attrs, %{"due_date" => nil}}]

  # Moving on the rolled-up axis sets the card's own due date.
  def move_ops(axis, card, _from, to, %Config{unit: unit}) when axis in ~w(due_date schedule) do
    current = card && card.due_date

    if current && date_key(current, unit) == to,
      do: [],
      else: [{:attrs, %{"due_date" => bucket_start(to)}}]
  end

  def move_ops(axis, _card, _from, _to, _config) when axis in ~w(created updated),
    do: [
      {:error, "Cards can't be moved between #{String.downcase(Config.axis_label(axis))} dates."}
    ]

  def move_ops("dependencies", _card, _from, _to, _config),
    do: [{:error, "Change dependencies from the card itself."}]

  def move_ops("goal", _card, _from, _to, _config),
    do: [{:error, "Link a card to a goal from the card itself."}]

  def move_ops("f:" <> _ = key, _card, _from, to, _config),
    do: [{:field, Config.custom_id(key), if(to == "none", do: nil, else: to)}]

  defp current_tag_ids(nil), do: []
  defp current_tag_ids(%{tags: tags}) when is_list(tags), do: Enum.map(tags, & &1.id)
  defp current_tag_ids(_), do: []

  defp parse_int(nil), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> nil
    end
  end
end
