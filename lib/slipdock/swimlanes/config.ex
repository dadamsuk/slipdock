defmodule Slipdock.Swimlanes.Config do
  @moduledoc """
  The configuration of a swimlane view: which card attribute sits on each
  axis, how dates are bucketed, how cards are sorted inside a cell, the
  filters (including `kinds` — cards, documents, wiki pages; see
  `Slipdock.Kinds`), and display options.

  A config can be encoded as query parameters (`to_query/2` emits only the
  keys that differ from a base config, so URLs stay short) and as a plain
  string-keyed map for storage in a saved view (`to_map/1`).
  """

  @axes [
    {"none", "None"},
    {"column", "List"},
    {"assignee", "Assignee"},
    {"priority", "Priority"},
    {"tag", "Tag"},
    {"flag", "Flag"},
    {"completed", "Status"},
    {"color", "Cover colour"},
    {"due_date", "Due date"},
    {"schedule", "Due (rolled up)"},
    {"created", "Created"},
    {"updated", "Last updated"},
    {"dependencies", "Dependencies"},
    {"goal", "Goal (contributes to)"}
  ]

  @units [
    {"day", "Days"},
    {"week", "Weeks"},
    {"month", "Months"},
    {"quarter", "Quarters"},
    {"year", "Years"}
  ]

  @sorts [
    {"position", "Board order"},
    {"title", "Title"},
    {"priority", "Priority"},
    {"start_date", "Start date"},
    {"due_date", "Due date"},
    {"schedule", "Due (rolled up)"},
    {"percent_complete", "% complete"},
    {"created", "Created"},
    {"updated", "Last updated"}
  ]

  @dues [
    {"", "Any"},
    {"overdue", "Overdue"},
    {"today", "Due today"},
    {"week", "Next 7 days"},
    {"month", "Next 30 days"},
    {"has", "Has a date"},
    {"none", "No date"}
  ]

  @dones [{"all", "All cards"}, {"hide", "Hide completed"}, {"only", "Only completed"}]
  @deps [
    {"", "Any"},
    {"blocked", "Blocked"},
    {"ready", "Not blocked"},
    {"blocking", "Blocks others"},
    {"violated", "Dates conflict"},
    {"free", "No dependencies"}
  ]
  # What colours a card's bar or cover strip.
  @colorings [
    {"cover", "Cover colour"},
    {"column", "List"},
    {"priority", "Priority"},
    {"health", "Health"},
    {"stated", "Reported health"},
    {"assignee", "Assignee"},
    {"tag", "First tag"}
  ]
  @empties ~w(hide show)
  @densities [{"normal", "Comfortable"}, {"compact", "Compact"}]
  # Which date a calendar puts a card on.
  @places [{"due", "Due date"}, {"start", "Start date"}]

  # What a card (or row, or chip) can show. Each density keeps its own set.
  @facets [
    {"cover", "Cover colour"},
    {"status", "Status"},
    {"tags", "Tags"},
    {"priority", "Priority"},
    {"flags", "Flags"},
    {"assignee", "Assignee"},
    {"start_date", "Start date"},
    {"due_date", "Due date"},
    {"percent_complete", "% complete"},
    {"time", "Time tracked"},
    {"dependencies", "Dependencies"},
    {"subcards", "Subcards"},
    {"checklist", "Checklist"},
    {"description", "Description"},
    {"comments", "Comments"},
    {"attachments", "Attachments"}
  ]
  @facet_keys Enum.map(@facets, &elem(&1, 0))
  @default_show_compact ~w(cover status priority flags assignee due_date)
  # Views that render less than a full card only offer the facets they can show.
  @mode_facets %{
    "outline" => ~w(cover status tags priority flags assignee),
    "timeline" => ~w(cover priority flags subcards),
    "calendar" => ~w(cover status tags priority flags start_date due_date),
    "narrative" => []
  }
  @dirs ~w(asc desc)

  # What a narrative tells: which kinds of event it includes, and which
  # extra sections it shows. `comment_text` and `subcards` qualify the
  # events; the rest of the second group are sections of the page.
  @tell_events [
    {"created", "Added"},
    {"completed", "Completed / reopened"},
    {"moved", "Moved between lists"},
    {"due", "Due date changes"},
    {"start", "Start date changes"},
    {"assigned", "Assignments"},
    {"comments", "Comments"},
    {"comment_text", "Comment text"},
    {"status", "Status reports"},
    {"votes", "Votes"},
    {"archived", "Archived / restored"},
    {"attachments", "Attachments"},
    {"edits", "Other edits"},
    {"subcards", "Subcard events"}
  ]
  @tell_sections [
    {"summary", "Card summary (current values)"},
    {"unchanged", "Unchanged cards"},
    {"milestones", "Milestones"},
    {"board", "Board changes"}
  ]
  @tell_keys Enum.map(@tell_events ++ @tell_sections, &elem(&1, 0))
  @default_tell @tell_keys -- ["summary"]

  @modes ~w(board swimlanes table timeline calendar outline narrative prioritise)
  @scalar_fields ~w(mode rows cols unit depth sort dir q due done deps empty density date place color_by span from to)a
  # Per-visit state that a saved view must not pin: the timeline/calendar
  # anchor date, and a narrative's explicit range (its span is kept, so a
  # saved narrative stays relative to today).
  @transient_fields ~w(date from to)a
  @spans ~w(7 14 30 90)
  @list_fields ~w(kinds tags priorities flags columns colors fields fields_compact show show_compact tell)a
  # Lists that a submitted form clears when absent (unchecked checkboxes are
  # not sent). The display choosers (`fields`, `show` and their compact
  # twins) are excluded: only the active density's chooser is on the form.
  @form_list_fields ~w(kinds tags priorities flags columns colors)a
  @filter_fields ~w(q due done deps kinds tags priorities flags columns colors)a

  defstruct mode: "swimlanes",
            rows: "priority",
            cols: "column",
            unit: "week",
            depth: "all",
            sort: "position",
            dir: "asc",
            q: "",
            due: nil,
            done: "all",
            deps: nil,
            empty: "hide",
            density: "normal",
            date: nil,
            place: "due",
            color_by: "cover",
            span: "14",
            from: nil,
            to: nil,
            kinds: [],
            tags: [],
            priorities: [],
            flags: [],
            columns: [],
            colors: [],
            fields: ~w(title column priority tags due_date completed),
            fields_compact: ~w(title column priority tags due_date completed),
            show: @facet_keys,
            show_compact: @default_show_compact,
            tell: @default_tell,
            # Facets the board itself puts out of sight (a simple board's
            # technical ones, see `Slipdock.Boards.Board.hidden_facets/1`).
            # Set from the board when a view is drawn, never stored or put in
            # a URL, and left alone by `show`, so a saved view keeps them.
            hidden: []

  @type t :: %__MODULE__{}

  def axes, do: @axes
  def modes, do: @modes

  @doc """
  The starting config for a view mode: swimlanes group two ways, tables,
  timelines and outlines don't group, calendars show a month. An outline's
  `depth` is how many levels of subcards it shows ("all" or a number).
  """
  def defaults("board"), do: %__MODULE__{mode: "board", rows: "none", cols: "none"}
  def defaults("table"), do: %__MODULE__{mode: "table", rows: "none", cols: "none"}

  def defaults("timeline"),
    do: %__MODULE__{mode: "timeline", rows: "none", cols: "none", sort: "start_date", depth: "1"}

  def defaults("calendar"),
    do: %__MODULE__{mode: "calendar", rows: "none", cols: "none", unit: "month"}

  def defaults("outline"), do: %__MODULE__{mode: "outline", rows: "none", cols: "none"}
  def defaults("narrative"), do: %__MODULE__{mode: "narrative", rows: "none", cols: "none"}

  def defaults("prioritise"),
    do: %__MODULE__{mode: "prioritise", rows: "none", cols: "none", done: "hide"}

  def defaults(_), do: %__MODULE__{}
  def mode_label("board"), do: "Board"
  def mode_label("table"), do: "Table"
  def mode_label("timeline"), do: "Timeline"
  def mode_label("calendar"), do: "Calendar"
  def mode_label("outline"), do: "Outline"
  def mode_label("narrative"), do: "Narrative"
  def mode_label("prioritise"), do: "Prioritise"
  def mode_label(_), do: "Swimlanes"
  def units, do: @units
  def sorts, do: @sorts
  def dues, do: @dues
  def dones, do: @dones
  def deps, do: @deps
  def densities, do: @densities
  def places, do: @places
  def colorings, do: @colorings
  def coloring_label(key), do: label(@colorings, key)

  @doc "The facets a view mode can show, as `{key, label}` (all of them for card views)."
  def facets(mode \\ nil) do
    case Map.fetch(@mode_facets, to_string(mode)) do
      {:ok, keys} -> Enum.filter(@facets, fn {k, _} -> k in keys end)
      :error -> @facets
    end
  end

  def facet_keys, do: @facet_keys

  @doc "What a narrative can tell, as `{key, label}`: the event kinds, then the page sections."
  def tell_events, do: @tell_events
  def tell_sections, do: @tell_sections
  def tell_keys, do: @tell_keys

  @doc "Whether the narrative config includes `key` (see `tell_events/0` and `tell_sections/0`)."
  def tells?(%__MODULE__{tell: tell}, key), do: key in tell

  @doc "The facets shown at the config's density, as a MapSet."
  def shown(%__MODULE__{density: "compact", show_compact: keys, hidden: hidden}),
    do: MapSet.new(keys -- hidden)

  def shown(%__MODULE__{show: keys, hidden: hidden}), do: MapSet.new(keys -- hidden)

  @doc "Sets the facets the board hides (see the `hidden` field)."
  def hide(%__MODULE__{} = config, keys), do: %{config | hidden: keys}

  @doc "The table columns chosen for the config's density."
  def table_fields(%__MODULE__{density: "compact", fields_compact: fields}), do: fields
  def table_fields(%__MODULE__{fields: fields}), do: fields
  def filter_fields, do: @filter_fields
  def list_fields, do: @list_fields

  @doc "Whether an axis, sort or table column key names a custom field (`f:<id>`)."
  def custom?(key) when is_binary(key), do: Regex.match?(~r/^f:\d+$/, key)
  def custom?(_), do: false

  @doc "The custom field id in a `f:<id>` key, or nil."
  def custom_id("f:" <> id) do
    case Integer.parse(id) do
      {i, ""} -> i
      _ -> nil
    end
  end

  def custom_id(_), do: nil

  @doc "The custom field named by an axis/sort/column key, from the board's fields."
  def custom_field(key, board) do
    case custom_id(key) do
      nil -> nil
      id -> Enum.find(Map.get(board, :fields) || [], &(&1.id == id))
    end
  end

  @doc "A label for an axis key, using the board's custom fields for `f:<id>` keys."
  def axis_label(axis, board) do
    case custom_field(axis, board) do
      nil -> axis_label(axis)
      field -> field.name
    end
  end

  def axis_label(axis), do: label(@axes, axis)
  def unit_label(unit), do: label(@units, unit)
  def sort_label(sort), do: label(@sorts, sort)
  def due_label(due), do: label(@dues, due || "")

  defp label(pairs, key) do
    case List.keyfind(pairs, key, 0) do
      {_, l} -> l
      nil -> key
    end
  end

  def date_axis?(axis), do: axis in ~w(due_date schedule created updated)
  def movable?(axis), do: axis not in ~w(created updated dependencies goal)

  @doc "Sort keys as `{key, label}`, with the board's numeric custom fields and votes."
  def sorts(board) do
    @sorts ++
      [{"votes", "Votes"}] ++
      for f <- Map.get(board, :fields) || [], do: {"f:#{f.id}", f.name}
  end

  @doc "Axis keys as `{key, label}`, with the board's rating and choice fields."
  def axes(board) do
    @axes ++
      for f <- Map.get(board, :fields) || [],
          f.kind in ~w(rating select),
          do: {"f:#{f.id}", f.name}
  end

  def uses_dates?(%__MODULE__{rows: r, cols: c}), do: date_axis?(r) or date_axis?(c)

  @doc """
  Builds a config from URL/query params on top of `base`. Keys that are
  absent keep the value from `base`; a present key with an invalid value also
  falls back to `base`. List values accept both lists and comma-joined
  strings; an empty string clears the list.
  """
  def from_query(params, %__MODULE__{} = base \\ %__MODULE__{}) when is_map(params) do
    Enum.reduce(@scalar_fields ++ @list_fields, base, fn field, acc ->
      case Map.fetch(params, Atom.to_string(field)) do
        {:ok, raw} -> Map.put(acc, field, cast(field, raw, Map.fetch!(base, field)))
        :error -> acc
      end
    end)
  end

  @doc """
  Builds a config from a submitted form. Like `from_query/2`, except that
  list fields absent from the params are treated as empty, since unchecked
  checkboxes are simply not sent.
  """
  def from_form(params, %__MODULE__{} = current) do
    params = Map.merge(Map.new(@form_list_fields, &{Atom.to_string(&1), []}), params)
    config = from_query(params, current)

    # A view's chooser only lists the facets it can show; the rest stay as they were.
    # So do the ones the board hides, which the chooser leaves out too.
    unlisted = (@facet_keys -- Enum.map(facets(current.mode), &elem(&1, 0))) ++ current.hidden

    %{
      config
      | show: keep_unlisted(config.show, current.show, unlisted),
        show_compact: keep_unlisted(config.show_compact, current.show_compact, unlisted)
    }
  end

  defp keep_unlisted(new, old, unlisted),
    do: ordered(new ++ Enum.filter(old, &(&1 in unlisted)), @facet_keys)

  @doc "Builds a config from a stored string-keyed map."
  def from_map(map) when is_map(map), do: from_query(map, %__MODULE__{})
  def from_map(_), do: %__MODULE__{}

  @doc "Encodes the config as a string-keyed map suitable for JSON storage."
  def to_map(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.drop([:hidden | @transient_fields])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  @doc "The anchor date of a timeline or calendar: the `date` param, else today."
  def anchor(%__MODULE__{date: nil}, today), do: today
  def anchor(%__MODULE__{date: iso}, _today), do: Date.from_iso8601!(iso)

  @doc """
  Encodes the keys of `config` that differ from `base` as a keyword list of
  query parameters.
  """
  def to_query(%__MODULE__{} = config, %__MODULE__{} = base \\ %__MODULE__{}) do
    for field <- @scalar_fields ++ @list_fields,
        value = Map.fetch!(config, field),
        value != Map.fetch!(base, field) do
      {field, encode(value)}
    end
  end

  defp encode(nil), do: ""
  defp encode(list) when is_list(list), do: Enum.map_join(list, ",", &to_string/1)
  defp encode(other), do: to_string(other)

  @doc "Drops references to tags and lists that no longer exist on the board."
  def sanitize(%__MODULE__{} = config, board) do
    tag_ids = MapSet.new(board.tags, & &1.id)
    col_ids = MapSet.new(board.columns, & &1.id)

    field_ids = MapSet.new(Map.get(board, :fields) || [], & &1.id)
    known? = fn key -> not custom?(key) or MapSet.member?(field_ids, custom_id(key)) end
    defaults = defaults(config.mode)

    %{
      config
      | tags: Enum.filter(config.tags, &MapSet.member?(tag_ids, &1)),
        columns: Enum.filter(config.columns, &MapSet.member?(col_ids, &1)),
        rows: if(known?.(config.rows), do: config.rows, else: defaults.rows),
        cols: if(known?.(config.cols), do: config.cols, else: defaults.cols),
        sort: if(known?.(config.sort), do: config.sort, else: defaults.sort),
        fields: Enum.filter(config.fields, known?),
        fields_compact: Enum.filter(config.fields_compact, known?)
    }
  end

  @doc "Returns the config with every filter reset."
  def clear_filters(%__MODULE__{} = config) do
    defaults = %__MODULE__{}
    Enum.reduce(@filter_fields, config, &Map.put(&2, &1, Map.fetch!(defaults, &1)))
  end

  def filtering?(%__MODULE__{} = config), do: active_filter_count(config) > 0

  def active_filter_count(%__MODULE__{} = config) do
    Enum.count(@filter_fields, fn field ->
      Map.fetch!(config, field) != Map.fetch!(%__MODULE__{}, field)
    end)
  end

  ## Casting -----------------------------------------------------------------

  defp cast(:mode, v, d), do: pick(v, @modes, d)
  defp cast(:rows, v, d), do: pick_or_custom(v, Enum.map(@axes, &elem(&1, 0)), d)
  defp cast(:cols, v, d), do: pick_or_custom(v, Enum.map(@axes, &elem(&1, 0)), d)
  defp cast(:unit, v, d), do: pick(v, Enum.map(@units, &elem(&1, 0)), d)

  defp cast(:depth, v, d),
    do: pick(v, ["all" | Enum.map(1..Slipdock.Outline.max_depth()//1, &to_string/1)], d)

  defp cast(:sort, v, d), do: pick_or_custom(v, ["votes" | Enum.map(@sorts, &elem(&1, 0))], d)
  defp cast(:dir, v, d), do: pick(v, @dirs, d)
  defp cast(:done, v, d), do: pick(v, Enum.map(@dones, &elem(&1, 0)), d)
  defp cast(:empty, v, d), do: pick(v, @empties, d)
  defp cast(:density, v, d), do: pick(v, Enum.map(@densities, &elem(&1, 0)), d)
  defp cast(:place, v, d), do: pick(v, Enum.map(@places, &elem(&1, 0)), d)
  defp cast(:color_by, v, d), do: pick(v, Enum.map(@colorings, &elem(&1, 0)), d)
  defp cast(:span, v, d), do: pick(v, @spans, d)
  defp cast(:from, v, d), do: cast(:date, v, d)
  defp cast(:to, v, d), do: cast(:date, v, d)
  defp cast(:q, v, _) when is_binary(v), do: String.trim(v)
  defp cast(:q, _, d), do: d
  defp cast(:date, "", _), do: nil

  defp cast(:date, v, d) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> d
    end
  end

  defp cast(:date, _, d), do: d

  defp cast(:due, v, d) do
    case pick(v, Enum.map(@dues, &elem(&1, 0)), d) do
      "" -> nil
      other -> other
    end
  end

  defp cast(:deps, v, d) do
    case pick(v, Enum.map(@deps, &elem(&1, 0)), d) do
      "" -> nil
      other -> other
    end
  end

  defp cast(:kinds, v, _), do: ordered(v, Slipdock.Kinds.keys())
  defp cast(:tags, v, _), do: int_list(v)
  defp cast(:columns, v, _), do: int_list(v)
  defp cast(:priorities, v, _), do: str_list(v, Slipdock.Boards.Card.priorities())
  defp cast(:flags, v, _), do: str_list(v, Slipdock.Boards.Card.flags())
  defp cast(:colors, v, _), do: str_list(v, ["none" | Slipdock.Palette.names()])
  # Fields are kept in display order so the same selection always encodes the
  # same way; custom field columns (`f:<id>`) follow the built-in ones.
  defp cast(:fields, v, _), do: ordered_with_custom(v, Slipdock.Table.field_keys())
  defp cast(:fields_compact, v, _), do: ordered_with_custom(v, Slipdock.Table.field_keys())

  defp cast(:show, v, _), do: ordered(v, @facet_keys)
  defp cast(:show_compact, v, _), do: ordered(v, @facet_keys)
  defp cast(:tell, v, _), do: ordered(v, @tell_keys)

  defp ordered_with_custom(v, keys) do
    all = v |> items() |> Enum.map(&to_string/1) |> Enum.uniq()
    ordered(all, keys) ++ Enum.filter(all, &custom?/1)
  end

  defp pick_or_custom(v, allowed, default) when is_binary(v) do
    if v in allowed or custom?(v), do: v, else: default
  end

  defp pick_or_custom(_, _, default), do: default

  defp ordered(v, keys) do
    v |> str_list(keys) |> Enum.sort_by(&Enum.find_index(keys, fn k -> k == &1 end))
  end

  defp pick(v, allowed, default) when is_binary(v) do
    if v in allowed, do: v, else: default
  end

  defp pick(_, _, default), do: default

  defp int_list(v) do
    v
    |> items()
    |> Enum.flat_map(fn s ->
      case Integer.parse(to_string(s)) do
        {i, ""} -> [i]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp str_list(v, allowed) do
    v |> items() |> Enum.map(&to_string/1) |> Enum.filter(&(&1 in allowed)) |> Enum.uniq()
  end

  defp items(list) when is_list(list), do: list
  defp items(""), do: []
  defp items(s) when is_binary(s), do: String.split(s, ",", trim: true)
  defp items(_), do: []
end
