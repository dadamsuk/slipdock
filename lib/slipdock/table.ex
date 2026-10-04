defmodule Slipdock.Table do
  @moduledoc """
  The table view: which columns (fields) a table can show, and the grouped,
  filtered, sorted rows for a board. Filtering, sorting and grouping reuse
  `Slipdock.Swimlanes`; a table is a swimlane grid with a single column.
  """

  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config

  @fields [
    {"title", "Title", "title"},
    {"column", "List", "position"},
    {"priority", "Priority", "priority"},
    {"assignee", "Assignee", nil},
    {"flags", "Flags", nil},
    {"tags", "Tags", nil},
    {"start_date", "Start", "start_date"},
    {"due_date", "Due", "due_date"},
    {"completed", "Done", nil},
    {"percent_complete", "% complete", "percent_complete"},
    {"time", "Time", nil},
    {"checklist", "Checklist", nil},
    {"comments", "Comments", nil},
    {"dependencies", "Dependencies", nil},
    {"subcards", "Subcards", nil},
    {"health", "Health", nil},
    {"goal", "Goal", nil},
    {"links", "Links", nil},
    {"color", "Cover", nil},
    {"created", "Created", "created"},
    {"updated", "Updated", "updated"},
    {"id", "ID", nil}
  ]

  @default_fields ~w(title column priority tags due_date completed)

  @doc "All built-in fields as `{key, label, sort_key_or_nil}`, in display order."
  def fields, do: @fields
  # Votes count as a built-in key: the chooser offers them, so a config must keep them.
  def field_keys, do: Enum.map(@fields, &elem(&1, 0)) ++ ["votes"]
  def default_fields, do: @default_fields

  @doc "Built-in fields, then votes, then the board's custom fields as `f:<id>` columns."
  def fields(board) do
    @fields ++
      [{"votes", "Votes", "votes"}] ++
      for f <- Map.get(board, :fields) || [], do: {"f:#{f.id}", f.name, "f:#{f.id}"}
  end

  def field_label(key, board \\ nil) do
    case List.keyfind(fields(board || %{}), key, 0) do
      {_, label, _} -> label
      nil -> key
    end
  end

  @doc """
  The visible fields in display order for the config's density; the title is
  always shown first.
  """
  def visible_fields(%Config{} = config, board \\ nil) do
    chosen = Config.table_fields(config)
    Enum.filter(fields(board || %{}), fn {key, _, _} -> key == "title" or key in chosen end)
  end

  @doc """
  Per group, the totals of the board's summable fields over the group's
  cards (own values, not rolled up): `[{field, total}]`, skipping fields no
  card in the group has a value for.
  """
  def group_sums(cards, board) do
    for field <- Map.get(board, :fields) || [],
        field.sum,
        values = cards |> Enum.map(&Slipdock.Fields.numeric(&1, field)) |> Enum.reject(&is_nil/1),
        values != [],
        do: {field, Enum.sum(values)}
  end

  @doc """
  The table as CSV text: the visible fields (plus a Group column when the
  rows are grouped), one line per card, in the table's order.
  """
  def csv(board, %Config{} = config, today \\ Date.utc_today()) do
    rows = rows(board, config, today)
    fields = visible_fields(config, board)
    col_names = Map.new(board.columns, &{&1.id, &1.name})
    by_key = Map.new(Map.get(board, :fields) || [], &{"f:#{&1.id}", &1})

    header =
      if(rows.grouped, do: ["Group"], else: []) ++ Enum.map(fields, fn {_, label, _} -> label end)

    lines =
      for group <- rows.groups, card <- group.cards do
        if(rows.grouped, do: [group.label], else: []) ++
          Enum.map(fields, fn {key, _, _} -> cell_text(key, card, {col_names, by_key}) end)
      end

    [header | lines]
    |> Enum.map(fn line -> Enum.map_join(line, ",", &csv_escape/1) end)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp cell_text("title", card, _), do: card.title
  defp cell_text("column", card, {names, _}), do: Map.get(names, card.column_id, "")
  defp cell_text("votes", card, _), do: to_string(Slipdock.Boards.Card.vote_total(card))

  defp cell_text("goal", card, _),
    do: Enum.map_join(Slipdock.Boards.Card.goals(card), "; ", & &1.title)

  defp cell_text("links", card, _) do
    out = if is_list(card.links_out), do: card.links_out, else: []
    inn = if is_list(card.links_in), do: card.links_in, else: []

    Enum.map_join(out, "; ", &"#{&1.kind} #{&1.to.title}") <>
      if(inn != [] and out != [], do: "; ", else: "") <>
      Enum.map_join(inn, "; ", &"#{&1.kind} from #{&1.from.title}")
  end

  defp cell_text("f:" <> _ = key, card, {_, by_key}) do
    case Map.get(by_key, key) do
      nil -> ""
      field -> Slipdock.Fields.format(field, Slipdock.Fields.value(card, field)) || ""
    end
  end

  defp cell_text("priority", card, _), do: card.priority

  defp cell_text("assignee", card, _),
    do:
      card
      |> Slipdock.Boards.Card.assignees()
      |> Enum.map_join("; ", &Slipdock.Accounts.User.display_name/1)

  defp cell_text("flags", card, _), do: Enum.join(card.flags, "; ")
  defp cell_text("tags", card, _), do: Enum.map_join(card.tags, "; ", & &1.name)
  defp cell_text("start_date", card, _), do: iso(Slipdock.Boards.Card.effective_start(card))
  defp cell_text("due_date", card, _), do: iso(Slipdock.Boards.Card.effective_due(card))
  defp cell_text("completed", card, _), do: if(card.completed, do: "yes", else: "no")

  defp cell_text("percent_complete", card, _),
    do: if(card.percent_complete, do: "#{card.percent_complete}%", else: "")

  defp cell_text("time", card, _) do
    unit = Map.get(card, :time_unit) || Slipdock.TimeTracking.default_unit()
    spent = Slipdock.TimeTracking.spent(card)

    case {Slipdock.TimeTracking.tracked?(card), Map.get(card, :time_estimate)} do
      {false, _} ->
        ""

      {true, nil} ->
        Slipdock.TimeTracking.format(spent, unit)

      {true, est} ->
        "#{Slipdock.TimeTracking.format(spent, unit)} / #{Slipdock.TimeTracking.format(est, unit)}"
    end
  end

  defp cell_text("checklist", card, _) do
    items = if is_list(card.checklist_items), do: card.checklist_items, else: []
    if items == [], do: "", else: "#{Enum.count(items, & &1.done)}/#{length(items)}"
  end

  defp cell_text("comments", card, _),
    do: if(is_list(card.comments), do: to_string(length(card.comments)), else: "")

  defp cell_text("dependencies", card, _) do
    blocked_by = if is_list(card.blocked_by), do: card.blocked_by, else: []
    blocks = if is_list(card.blocks), do: card.blocks, else: []

    [
      if(blocked_by != [], do: "blocked by: " <> Enum.map_join(blocked_by, "; ", & &1.title)),
      if(blocks != [], do: "blocks: " <> Enum.map_join(blocks, "; ", & &1.title))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  defp cell_text("subcards", card, _) do
    case Slipdock.Boards.Card.progress(card) do
      {done, total} -> "#{done}/#{total}"
      nil -> ""
    end
  end

  defp cell_text("health", card, _) do
    computed = Slipdock.Boards.Card.health(card)
    stated = Slipdock.Boards.Card.stated_health(card)

    [computed && to_string(computed), stated && "reported #{stated}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp cell_text("color", card, _), do: card.color || ""
  defp cell_text("created", card, _), do: DateTime.to_iso8601(card.inserted_at)
  defp cell_text("updated", card, _), do: DateTime.to_iso8601(card.updated_at)
  defp cell_text("id", card, _), do: to_string(card.id)
  defp cell_text(_, _, _), do: ""

  defp iso(nil), do: ""
  defp iso(%Date{} = d), do: Date.to_iso8601(d)

  defp csv_escape(value) do
    text = to_string(value)

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  @doc """
  Groups (from the config's `rows` axis), each with its filtered and sorted
  cards, plus shown/hidden counts. With `rows: "none"` there is one group.
  """
  def rows(board, %Config{} = config, today \\ Date.utc_today()) do
    grid = Swimlanes.grid(board, %{config | cols: "none"}, today)

    groups =
      Enum.map(grid.rows, fn row ->
        row |> Map.delete(:cells) |> Map.put(:cards, List.flatten(row.cells))
      end)

    %{groups: groups, grouped: config.rows != "none", shown: grid.shown, hidden: grid.hidden}
  end
end
