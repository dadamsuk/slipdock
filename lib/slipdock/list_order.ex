defmodule Slipdock.ListOrder do
  @moduledoc """
  How one list draws its cards, from the list's own settings: in the order
  they were dragged into (the default), or sorted by an attribute, and either
  as one run or grouped under headings.

  It only changes the drawing. A card's `position` is still the order it was
  put in, and comes back the moment the list is set to board order again;
  cards that tie on the sort keep that order between them.

  Everything here is pure: it is handed the list's items (cards and the wiki
  pages placed in it, already filtered) and returns them arranged.
  """

  alias Slipdock.Boards.Column
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config

  @sorts [
    {"", "Board order (drag to arrange)"},
    {"created", "Created"},
    {"updated", "Last updated"},
    {"start_date", "Start date"},
    {"due_date", "Due date"},
    {"priority", "Priority"}
  ]

  @dirs [{"asc", "Earliest / lowest first"}, {"desc", "Latest / highest first"}]

  @groups [
    {"", "No grouping"},
    {"flag", "Flags"},
    {"tag", "Tags"},
    {"start_date", "Start date"},
    {"due_date", "Due date"}
  ]

  @date_groups ~w(past today week next_week later none)

  def sorts, do: @sorts
  def sort_keys, do: @sorts |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))
  def dirs, do: @dirs
  def dir_keys, do: Enum.map(@dirs, &elem(&1, 0))
  def groups, do: @groups
  def group_keys, do: @groups |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))

  @doc "Whether the list draws its cards in an order of its own rather than by hand."
  def sorted?(%Column{sort_by: sort}), do: not is_nil(sort)
  def sorted?(_), do: false

  @doc "A short description of how the list is arranged, or nil for board order and no groups."
  def label(%Column{sort_by: nil, group_by: nil}), do: nil

  def label(%Column{} = column) do
    [
      column.sort_by && "by #{String.downcase(name(@sorts, column.sort_by))}",
      column.sort_by && column.sort_dir == "desc" && "descending",
      column.group_by && "grouped by #{String.downcase(name(@groups, column.group_by))}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  @doc "`items` in the list's sort order."
  def sort(items, %Column{sort_by: nil}), do: items

  def sort(items, %Column{sort_by: sort, sort_dir: dir}),
    do: Swimlanes.sort(items, %Config{sort: sort, dir: dir || "asc"})

  @doc """
  The list's items, sorted, as groups: `[%{key, label, color, items}]`, in
  the order the groups are drawn, empty ones left out. Ungrouped, it is one
  group with a nil label.

  Tags and flags are multi-valued, but a card is drawn once: it goes under
  the first of its tags (in the board's tag order) or flags it has.
  """
  def arrange(items, %Column{} = column, board, today \\ Date.utc_today()) do
    items = sort(items, column)

    case column.group_by do
      nil ->
        [%{key: "all", label: nil, color: nil, items: items}]

      by ->
        buckets = buckets(by, board)
        keys = Enum.map(buckets, & &1.key)
        by_key = Enum.group_by(items, &group_key(&1, by, keys, today))

        for bucket <- buckets, found = by_key[bucket.key], do: Map.put(bucket, :items, found)
    end
  end

  @doc "Which of `keys` (a group's buckets, in order) the item goes under."
  def group_key(item, by, keys, today \\ Date.utc_today())

  def group_key(item, "flag", keys, _today),
    do: Enum.find(keys, "none", &(&1 in item.flags))

  def group_key(item, "tag", keys, _today) do
    ids = MapSet.new(item.tags, &to_string(&1.id))
    Enum.find(keys, "none", &MapSet.member?(ids, &1))
  end

  def group_key(item, "start_date", _keys, today), do: date_group(item.start_date, today)
  def group_key(item, "due_date", _keys, today), do: date_group(item.due_date, today)

  @doc "Which relative bucket a date falls in, seen from `today`."
  def date_group(nil, _today), do: "none"

  def date_group(%Date{} = date, today) do
    end_of_week = Date.end_of_week(today)

    cond do
      Date.before?(date, today) -> "past"
      date == today -> "today"
      not Date.after?(date, end_of_week) -> "week"
      not Date.after?(date, Date.add(end_of_week, 7)) -> "next_week"
      true -> "later"
    end
  end

  defp buckets("flag", board), do: Swimlanes.buckets("flag", board, [], %Config{})
  defp buckets("tag", board), do: Swimlanes.buckets("tag", board, [], %Config{})
  defp buckets(by, _board), do: Enum.map(@date_groups, &date_bucket(&1, by))

  defp date_bucket(key, by),
    do: %{key: key, label: date_label(key, by), color: nil, tone: date_tone(key, by)}

  defp date_label("past", "due_date"), do: "Overdue"
  defp date_label("past", "start_date"), do: "Started"
  defp date_label("today", "due_date"), do: "Due today"
  defp date_label("today", "start_date"), do: "Starts today"
  defp date_label("week", _), do: "This week"
  defp date_label("next_week", _), do: "Next week"
  defp date_label("later", _), do: "Later"
  defp date_label("none", "due_date"), do: "No due date"
  defp date_label("none", "start_date"), do: "No start date"

  defp date_tone("past", "due_date"), do: :past
  defp date_tone("today", _), do: :current
  defp date_tone(_, _), do: nil

  defp name(options, key), do: options |> List.keyfind(key, 0, {key, key}) |> elem(1)
end
