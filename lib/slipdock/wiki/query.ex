defmodule Slipdock.Wiki.Query do
  @moduledoc ~S'''
  A live query written in a page: a fenced ```slipdock block, answered when the
  page is **read** rather than when it was written.

      ```slipdock
      view: table
      board: this
      filter: flag=blocked, due < +7d, priority in high|critical
      group: assignee
      sort: due_date asc
      fields: title, assignee, due_date, status
      limit: 20
      empty: "Nothing blocked and due this week."
      ```

  Two properties matter more than the syntax.

  **It is evaluated with the reader's permissions, every time.** Never at
  write time, and never with the author's. A document must not become a way
  to see cards you cannot open, so a board the reader cannot read is dropped
  before a single card is looked at.

  **It compiles to a `Slipdock.Swimlanes.Config`.** Every filter, sort,
  grouping and field chooser that exists in the UI is therefore available to
  a document on day one, and the UI can offer "insert this view into a doc"
  from any board view — which is the honest way to author one of these
  without learning the syntax. `filter:` beyond what a config expresses is
  handed to `Slipdock.Automations.Runner.conditions_match?/2`, so the condition
  vocabulary is the automations' one rather than a second dialect.

  This module answers with **data**. Drawing it is
  `SlipdockWeb.Wiki.Renderer`'s job for a screen and the API's for an agent,
  which is what lets `GET /api/pages/:id/render` hand back a Markdown table
  of the same answer.

  ## As built

  `docs/wiki.md` lists `timeline` and `calendar` among the views. A document
  is a column of text, not a canvas: those are implemented as presets of
  `table` and `board` — the same information, without pixels a paragraph has
  no room for. Link the real thing with `[[view:Blocked work]]` when the
  picture is the point.
  '''

  alias Slipdock.Automations.Runner
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Rollup
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table
  alias Slipdock.Automations.Spec
  alias Slipdock.{Access, Repo, Work}

  import Ecto.Query, warn: false

  @views ~w(table list board count progress timeline calendar)
  @keys ~w(view board filter group sort fields limit empty saved_view card assigned unit done)

  defstruct view: "table",
            board: "this",
            filters: [],
            group: "none",
            sort: nil,
            dir: "asc",
            unit: "week",
            fields: nil,
            limit: nil,
            empty: nil,
            saved_view: nil,
            card: nil,
            assigned: nil,
            done: nil,
            raw: ""

  @type t :: %__MODULE__{}

  def views, do: @views
  def keys, do: @keys

  ## Parsing ------------------------------------------------------------------

  @doc """
  Reads a block's text. `{:ok, query}`, or `{:error, message}` naming what
  was wrong — a message a person reads on the page, so it says what to write
  instead rather than what the parser felt.
  """
  @spec parse(String.t()) :: {:ok, t} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while({:ok, %__MODULE__{raw: text}}, fn line, {:ok, query} ->
      case line_into(line, query) do
        {:ok, query} -> {:cont, {:ok, query}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> validate()
  end

  def parse(_), do: {:error, "a slipdock block needs some lines in it"}

  defp validate({:ok, %__MODULE__{view: view} = query}) do
    if view in @views,
      do: {:ok, query},
      else: {:error, "view must be one of: #{Enum.join(@views, ", ")}"}
  end

  defp validate(other), do: other

  defp line_into(line, query) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        key = key |> String.trim() |> String.downcase()
        value = String.trim(value)

        if key in @keys,
          do: put(query, key, value),
          else: {:error, "#{inspect(key)} is not a setting here. Try: #{Enum.join(@keys, ", ")}"}

      _ ->
        {:error, "#{inspect(line)} should read `setting: value`"}
    end
  end

  defp put(query, "view", value), do: {:ok, %{query | view: String.downcase(value)}}
  defp put(query, "board", value), do: {:ok, %{query | board: value}}
  defp put(query, "group", value), do: {:ok, %{query | group: axis(value)}}
  defp put(query, "unit", value), do: {:ok, %{query | unit: value}}
  defp put(query, "saved_view", value), do: {:ok, %{query | saved_view: unquoted(value)}}
  defp put(query, "assigned", value), do: {:ok, %{query | assigned: value}}
  defp put(query, "empty", value), do: {:ok, %{query | empty: unquoted(value)}}

  defp put(query, "done", value) do
    case String.trim(String.downcase(value)) do
      v when v in ~w(all hide only) -> {:ok, %{query | done: v}}
      _ -> {:error, "done must be all, hide or only"}
    end
  end

  defp put(query, "card", value) do
    case Integer.parse(String.trim_leading(value, "#")) do
      {id, ""} -> {:ok, %{query | card: id}}
      _ -> {:error, "card must be a number, like `card: 412`"}
    end
  end

  defp put(query, "limit", value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, %{query | limit: min(n, 200)}}
      _ -> {:error, "limit must be a positive number"}
    end
  end

  defp put(query, "sort", value) do
    case String.split(value, ~r/\s+/, trim: true) do
      [field] -> {:ok, %{query | sort: field}}
      [field, "desc"] -> {:ok, %{query | sort: field, dir: "desc"}}
      [field, "asc"] -> {:ok, %{query | sort: field, dir: "asc"}}
      _ -> {:error, "sort reads `sort: due_date asc` (or desc)"}
    end
  end

  defp put(query, "fields", value) do
    {:ok, %{query | fields: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}}
  end

  defp put(query, "filter", value) do
    case parse_filters(value) do
      {:ok, filters} -> {:ok, %{query | filters: query.filters ++ filters}}
      error -> error
    end
  end

  defp unquoted(value), do: value |> String.trim() |> String.trim("\"") |> String.trim("'")

  # "status" reads better than "completed" in a document; both work.
  defp axis("status"), do: "completed"
  defp axis("list"), do: "column"
  defp axis(value), do: value |> String.trim() |> String.downcase()

  ## The filter mini-language -------------------------------------------------

  @doc """
  Parses `flag=blocked, due < +7d, priority in high|critical` into the
  condition maps `Slipdock.Automations.Runner` already evaluates.

  The operators, and what each means:

      field = value          is                 field != value      is not
      field ~ text           contains           field !~ text       does not contain
      field in a|b           any of             field not in a|b    none of
      field < value          before / less      field > value       after / greater
      field <= value         before or on       field >= value      after or on
      field within Nd        due within N days  field older than Nd
      field set              has a value        field not set
  """
  def parse_filters(text) do
    text
    |> split_clauses()
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, acc} ->
      case parse_clause(clause) do
        {:ok, {:unknown_field, field}} ->
          {:halt,
           {:error,
            "there is nothing called #{inspect(field)} to filter on. Try: #{Enum.join(filter_fields(), ", ")}"}}

        {:ok, condition} ->
          {:cont, {:ok, acc ++ [condition]}}

        error ->
          {:halt, error}
      end
    end)
  end

  # Commas separate clauses; a value's alternatives are separated by `|`, so
  # nothing here needs quoting.
  defp split_clauses(text),
    do: text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp parse_clause(clause) do
    cond do
      match = Regex.run(~r/^(\w+)\s+not\s+in\s+(.+)$/i, clause) ->
        [_, field, values] = match
        {:ok, condition(field, "none_of", alternatives(values))}

      match = Regex.run(~r/^(\w+)\s+in\s+(.+)$/i, clause) ->
        [_, field, values] = match
        {:ok, condition(field, "any_of", alternatives(values))}

      match = Regex.run(~r/^(\w+)\s+within\s+(\d+)\s*d?$/i, clause) ->
        [_, field, days] = match
        {:ok, condition(field, "within_days", String.to_integer(days))}

      match = Regex.run(~r/^(\w+)\s+older\s+than\s+(\d+)\s*d?$/i, clause) ->
        [_, field, days] = match
        {:ok, condition(field, "older_than_days", String.to_integer(days))}

      match = Regex.run(~r/^(\w+)\s+not\s+set$/i, clause) ->
        [_, field] = match
        {:ok, condition(field, "is_not_set", nil)}

      match = Regex.run(~r/^(\w+)\s+set$/i, clause) ->
        [_, field] = match
        {:ok, condition(field, "is_set", nil)}

      match = Regex.run(~r/^(\w+)\s*(<=|>=|!=|!~|=|~|<|>)\s*(.*)$/, clause) ->
        [_, field, op, value] = match
        {:ok, comparison(field, op, String.trim(value))}

      Regex.match?(~r/^\w+$/, clause) ->
        # A bare field name is the boolean reading: `blocked`, `completed`.
        {:ok, condition(clause, "is", true)}

      true ->
        {:error, "#{inspect(clause)} is not a filter. Try `flag=blocked` or `due < +7d`."}
    end
  end

  defp alternatives(values),
    do: values |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  # `<=` and `>=` on a date are the same comparison a day either side, which
  # keeps the runner's vocabulary to `before` and `after` rather than growing
  # it a pair of near-duplicates.
  defp comparison(field, op, value) do
    resolved = resolve_value(value)

    case {op, resolved} do
      {"=", v} -> condition(field, "is", v)
      {"!=", v} -> condition(field, "is_not", v)
      {"~", v} -> condition(field, "contains", v)
      {"!~", v} -> condition(field, "not_contains", v)
      {"<", %Date{} = d} -> condition(field, "before", Date.to_iso8601(d))
      {"<=", %Date{} = d} -> condition(field, "before", Date.to_iso8601(Date.add(d, 1)))
      {">", %Date{} = d} -> condition(field, "after", Date.to_iso8601(d))
      {">=", %Date{} = d} -> condition(field, "after", Date.to_iso8601(Date.add(d, -1)))
      {"<", v} -> condition(field, "lt", v)
      {"<=", v} -> condition(field, "lt", v)
      {">", v} -> condition(field, "gt", v)
      {">=", v} -> condition(field, "gt", v)
    end
  end

  # The names a document naturally uses, mapped onto the condition
  # vocabulary. One vocabulary, two spellings — not two vocabularies.
  @aliases %{
    "due" => "due_date",
    "start" => "start_date",
    "list" => "column",
    "status" => "completed",
    "done" => "completed",
    "percent" => "percent_complete",
    "tags" => "tag",
    "flags" => "flag",
    "age" => "age_days"
  }

  @doc "The names a filter clause may use, the friendly spellings included."
  def filter_fields, do: Enum.sort(Spec.condition_fields() ++ Map.keys(@aliases))

  defp condition(field, op, value) do
    name = field |> String.downcase() |> then(&Map.get(@aliases, &1, &1))

    if name in Spec.condition_fields() do
      %{"field" => name, "op" => op, "value" => value}
    else
      {:unknown_field, field}
    end
  end

  @doc """
  Reads a filter's value: `true`/`false`, a number, a date, or one of the
  relative dates a document wants — `today`, `tomorrow`, `+7d`, `-3d`.
  """
  def resolve_value(value) do
    trimmed = value |> String.trim() |> String.trim("\"") |> String.trim("'")

    cond do
      trimmed in ~w(true yes) -> true
      trimmed in ~w(false no) -> false
      trimmed == "today" -> Date.utc_today()
      trimmed == "tomorrow" -> Date.add(Date.utc_today(), 1)
      trimmed == "yesterday" -> Date.add(Date.utc_today(), -1)
      match = Regex.run(~r/^([+-])(\d+)\s*d$/i, trimmed) -> relative_date(match)
      match?({:ok, _}, Date.from_iso8601(trimmed)) -> Date.from_iso8601!(trimmed)
      match?({_, ""}, Integer.parse(trimmed)) -> trimmed |> Integer.parse() |> elem(0)
      true -> trimmed
    end
  end

  defp relative_date([_, sign, days]) do
    n = String.to_integer(days)
    Date.add(Date.utc_today(), if(sign == "-", do: -n, else: n))
  end

  ## Running ------------------------------------------------------------------

  @doc """
  Answers a query for one reader.

  `context` carries `:board` (the page's own board, which `board: this`
  means), `:reader` (a `%User{}` or nil for the system) and optionally
  `:today`.

  Returns `{:ok, result}` where result is one of the shapes below, or
  `{:error, message}`:

    * `%{kind: :table, headers:, rows:, count:, hidden:}` — rows carry the
      card as well as its cells, so a renderer can link the title
    * `%{kind: :list, cards:}`
    * `%{kind: :groups, groups: [%{label:, cards:}], count:}`
    * `%{kind: :count, count:}`
    * `%{kind: :progress, done:, total:, percent:, label:}`
  """
  @spec run(t, map) :: {:ok, map} | {:error, String.t()}
  def run(%__MODULE__{} = query, context) do
    today = context[:today] || Date.utc_today()

    cond do
      query.assigned -> run_assigned(query, context, today)
      query.card -> run_card(query, context, today)
      true -> run_cards(query, context, today)
    end
  rescue
    error -> {:error, "that query could not be answered (#{Exception.message(error)})"}
  end

  ## A person's work ----------------------------------------------------------

  defp run_assigned(%__MODULE__{} = query, context, today) do
    with {:ok, user} <- resolve_person(query.assigned, context) do
      entries =
        Work.assigned(user, context[:reader] || user, today: today)
        |> then(fn entries ->
          if query.board in [nil, "this", "tree"],
            do: Enum.filter(entries, &in_tree?(&1.card, context[:board])),
            else: entries
        end)

      cards = entries |> Enum.map(& &1.card) |> apply_filters(query) |> limited(query)

      case query.view do
        "count" -> {:ok, %{kind: :count, count: length(cards)}}
        "table" -> {:ok, table_of(cards, query, context[:board], today)}
        _ -> {:ok, %{kind: :list, cards: cards}}
      end
    end
  end

  defp resolve_person(ref, context) do
    reader = context[:reader]
    name = ref |> String.trim() |> String.trim_leading("@")

    cond do
      name in ~w(me myself mine) and reader -> {:ok, reader}
      name in ~w(me myself mine) -> {:error, "`assigned: me` needs to know who is reading"}
      true -> find_member(context[:board], name)
    end
  end

  defp find_member(nil, name), do: {:error, "no such person: #{inspect(name)}"}

  defp find_member(board, name) do
    wanted = String.downcase(name)

    board
    |> Slipdock.Wiki.Links.members()
    |> Enum.find(fn user ->
      String.downcase(user.email) == wanted or
        String.downcase(to_string(user.name)) == wanted or
        Slipdock.Wiki.Links.handle(user) == wanted
    end)
    |> case do
      nil -> {:error, "nobody on this board answers to #{inspect(name)}"}
      user -> {:ok, user}
    end
  end

  defp in_tree?(%Card{board_id: board_id}, %Board{} = board) do
    root = Board.root_id(board)

    Repo.exists?(
      from(b in Board, where: b.id == ^board_id and (b.id == ^root or b.root_id == ^root))
    )
  end

  defp in_tree?(_card, _board), do: true

  ## One card's tree ----------------------------------------------------------

  defp run_card(%__MODULE__{} = query, context, _today) do
    with %Card{} = card <- Repo.get(Card, query.card),
         true <- readable_card?(card, context[:reader]) do
      rollup = Rollup.build(Repo.get!(Board, card.board_id))

      case Rollup.stats(rollup, card.id) do
        nil ->
          {:ok, %{kind: :progress, done: 0, total: 0, percent: 0, label: card.title, card: card}}

        stats ->
          done = stats.done
          total = stats.total
          percent = if total > 0, do: round(done * 100 / total), else: 0

          {:ok,
           %{
             kind: :progress,
             done: done,
             total: total,
             percent: percent,
             label: card.title,
             card: card
           }}
      end
    else
      nil -> {:error, "there is no card ##{query.card}"}
      false -> {:error, "there is no card ##{query.card}"}
      other -> other
    end
  end

  defp readable_card?(_card, nil), do: true
  defp readable_card?(card, reader), do: Access.can_read?(Access.card_permission(reader, card))

  ## Cards on one or more boards ----------------------------------------------

  defp run_cards(%__MODULE__{} = query, context, today) do
    with {:ok, boards} <- resolve_boards(query.board, context),
         {:ok, config} <- build_config(query, boards, context) do
      # Loaded once each, and the loaded board is what the shaping sees: a
      # board found by code carries none of its columns or custom fields, and
      # a table header needs both.
      loaded = Enum.map(boards, &Boards.get_board!(&1.id))

      cards =
        loaded
        |> Enum.flat_map(fn board -> board_cards(board, config, today) end)
        |> apply_filters(query)

      total = length(cards)
      cards = limited(cards, query)

      {:ok, shape(query, cards, total, List.first(loaded), today)}
    end
  end

  defp shape(%__MODULE__{view: "count"}, cards, _total, _board, _today),
    do: %{kind: :count, count: length(cards)}

  defp shape(%__MODULE__{view: "progress"}, cards, _total, _board, _today) do
    total = length(cards)
    done = Enum.count(cards, & &1.completed)

    %{
      kind: :progress,
      done: done,
      total: total,
      percent: (total > 0 && round(done * 100 / total)) || 0,
      label: nil,
      card: nil
    }
  end

  defp shape(%__MODULE__{view: "list"} = query, cards, total, _board, _today),
    do: %{kind: :list, cards: cards, count: total, empty: query.empty}

  defp shape(%__MODULE__{view: view} = query, cards, total, board, today)
       when view in ["board", "calendar"] do
    groups = group_cards(cards, query, board, today)
    %{kind: :groups, groups: groups, count: total, empty: query.empty}
  end

  defp shape(%__MODULE__{} = query, cards, total, board, today) do
    if query.group in [nil, "none"] do
      table_of(cards, query, board, today) |> Map.put(:count, total)
    else
      %{
        kind: :groups,
        groups: group_cards(cards, query, board, today),
        count: total,
        empty: query.empty
      }
    end
  end

  # Grouping reuses the swimlane axes *and their buckets*, so "group: assignee"
  # in a document means exactly what it means on the board — including the
  # order, which is the board's own rather than alphabetical.
  defp group_cards(cards, %__MODULE__{} = query, board, today) do
    axis = if query.view == "board", do: "column", else: query.group || "none"
    axis = if query.view == "calendar" and axis in [nil, "none"], do: "due_date", else: axis

    if axis in [nil, "none"] do
      [%{label: nil, cards: cards}]
    else
      board = board || %Board{id: 0, columns: [], tags: [], milestones: [], fields: []}

      config = %Config{
        Config.defaults("table")
        | rows: axis,
          cols: "none",
          unit: query.unit,
          empty: "hide"
      }

      by_key =
        Enum.reduce(cards, %{}, fn card, acc ->
          Enum.reduce(Swimlanes.card_keys(card, axis, query.unit), acc, fn key, acc ->
            Map.update(acc, key, [card], &(&1 ++ [card]))
          end)
        end)

      axis
      |> Swimlanes.buckets(board, cards, config, today)
      |> Enum.map(&%{label: &1.label, cards: Map.get(by_key, &1.key, [])})
      |> Enum.reject(&(&1.cards == []))
    end
  end

  defp table_of(cards, %__MODULE__{} = query, board, today) do
    keys = query.fields || Table.default_fields()
    board = board || %Board{id: 0, fields: []}

    %{
      kind: :table,
      headers: Enum.map(keys, &Table.field_label(&1, board)),
      keys: keys,
      rows:
        Enum.map(cards, fn card ->
          %{card: card, cells: Enum.map(keys, &cell(card, &1, today))}
        end),
      count: length(cards),
      hidden: 0,
      empty: query.empty
    }
  end

  @doc "One table cell as plain text, so every renderer shows the same thing."
  def cell(card, key, today \\ Date.utc_today())
  def cell(card, "id", _today), do: "##{card.id}"
  def cell(card, "title", _today), do: card.title
  def cell(card, "column", _today), do: (card.column && card.column.name) || ""
  def cell(card, "priority", _today), do: if(card.priority == "none", do: "", else: card.priority)

  def cell(card, "assignee", _today),
    do: (card.assignee && Slipdock.Accounts.User.display_name(card.assignee)) || ""

  def cell(card, "flags", _today), do: Enum.join(card.flags, ", ")
  def cell(card, "tags", _today), do: Enum.map_join(loaded(card.tags), ", ", & &1.name)
  def cell(card, "start_date", _today), do: date_text(card.start_date)
  def cell(card, "due_date", _today), do: date_text(card.due_date)
  def cell(card, "completed", _today), do: if(card.completed, do: "done", else: "")
  def cell(card, "status", _today), do: cell(card, "completed", today())

  def cell(card, "percent_complete", _today),
    do: if(card.percent_complete, do: "#{card.percent_complete}%", else: "")

  def cell(card, "checklist", _today), do: checklist_text(card)
  def cell(card, "comments", _today), do: count_text(card.comments)
  def cell(card, "dependencies", _today), do: deps_text(card)
  def cell(card, "subcards", _today), do: subcards_text(card)
  def cell(card, "health", _today), do: health_text(card)
  def cell(card, "color", _today), do: card.color || ""
  def cell(card, "created", _today), do: stamp(card.inserted_at)
  def cell(card, "updated", _today), do: stamp(card.updated_at)
  def cell(card, "board", _today), do: board_name(card)
  def cell(_card, _key, _today), do: ""

  defp today, do: Date.utc_today()

  defp loaded(list) when is_list(list), do: list
  defp loaded(_), do: []

  defp date_text(nil), do: ""
  defp date_text(%Date{} = date), do: Date.to_iso8601(date)

  defp stamp(nil), do: ""
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")

  defp count_text(list) when is_list(list),
    do: if(list == [], do: "", else: to_string(length(list)))

  defp count_text(_), do: ""

  defp checklist_text(card) do
    case loaded(card.checklist_items) do
      [] -> ""
      items -> "#{Enum.count(items, & &1.done)}/#{length(items)}"
    end
  end

  defp deps_text(card) do
    blocked = length(loaded(card.blocked_by))
    blocks = length(loaded(card.blocks))

    [blocked > 0 && "waits on #{blocked}", blocks > 0 && "holds up #{blocks}"]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp subcards_text(%Card{rollup: %{total: total, done: done}})
       when is_integer(total) and total > 0,
       do: "#{done}/#{total}"

  defp subcards_text(_), do: ""

  defp health_text(%Card{rollup: %{health: health}}) when is_binary(health), do: health
  defp health_text(_), do: ""

  defp board_name(%Card{board: %Board{name: name}}), do: name
  defp board_name(_), do: ""

  ## Boards, configs and filtering --------------------------------------------

  defp resolve_boards("this", context), do: readable([context[:board]], context)
  defp resolve_boards(nil, context), do: readable([context[:board]], context)

  defp resolve_boards("tree", context) do
    case context[:board] do
      %Board{} = board ->
        root = Board.root_id(board)

        from(b in Board, where: b.id == ^root or b.root_id == ^root, order_by: [asc: b.id])
        |> Repo.all()
        |> readable(context)

      _ ->
        {:error, "`board: tree` needs a board to start from"}
    end
  end

  defp resolve_boards(ref, context) do
    case Boards.find_board(String.trim(ref)) do
      {:ok, board} -> readable([board], context)
      _ -> {:error, "there is no board called #{inspect(ref)}"}
    end
  end

  # The permission check, and the only one that matters: a document must not
  # become a way to see cards you cannot open.
  defp readable(boards, context) do
    reader = context[:reader]

    boards
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn board ->
      is_nil(reader) or Access.can_read?(Access.board_permission(reader, board))
    end)
    |> case do
      [] -> {:error, "no board here for you to read"}
      boards -> {:ok, boards}
    end
  end

  defp build_config(%__MODULE__{} = query, boards, context) do
    base =
      case query.saved_view do
        nil ->
          {:ok, Config.defaults("table")}

        name ->
          case Boards.find_saved_view(hd(boards), name) do
            {:ok, view} ->
              if is_nil(context[:reader]) or
                   Access.can_read?(Access.view_permission(context[:reader], view)),
                 do: {:ok, Config.from_map(view.config)},
                 else: {:error, "you can't open the #{inspect(name)} view"}

            _ ->
              {:error, "there is no saved view called #{inspect(name)} on that board"}
          end
      end

    with {:ok, config} <- base do
      {:ok,
       %{
         config
         | rows: "none",
           cols: "none",
           unit: query.unit,
           sort: query.sort || config.sort,
           dir: query.dir,
           done: query.done || config.done
       }}
    end
  end

  defp board_cards(%Board{} = loaded, %Config{} = config, today) do
    columns = Map.new(loaded.columns, &{&1.id, &1})

    loaded
    |> Table.rows(config, today)
    |> Map.get(:groups)
    |> Enum.flat_map(& &1.cards)
    # A card loaded through its board knows its column's id but not the
    # column; a table cell wants the name.
    |> Enum.map(&%{&1 | board: loaded, column: Map.get(columns, &1.column_id)})
  end

  # Anything the config cannot express is a condition, evaluated by the
  # automations' own runner rather than a second implementation of "is".
  defp apply_filters(cards, %__MODULE__{filters: []}), do: cards

  defp apply_filters(cards, %__MODULE__{filters: filters}),
    do: Enum.filter(cards, &Runner.conditions_match?(filters, &1))

  defp limited(cards, %__MODULE__{limit: nil}), do: cards
  defp limited(cards, %__MODULE__{limit: n}), do: Enum.take(cards, n)

  ## Writing a block from a view ----------------------------------------------

  @doc """
  Turns a board view into the block that would reproduce it in a document.

  This is the honest way to author one of these: point at the view you
  already made, and let the app write the syntax. `view` is a saved view to
  name rather than spell out.
  """
  @spec to_block(Config.t(), Board.t(), keyword) :: String.t()
  def to_block(%Config{} = config, %Board{} = board, opts \\ []) do
    saved = opts[:saved_view]

    lines =
      ["view: #{block_view(config.mode)}", "board: this"] ++
        saved_or_filters(config, board, saved) ++
        group_line(config) ++
        sort_line(config) ++
        fields_line(config)

    "```slipdock\n" <> Enum.join(lines, "\n") <> "\n```\n"
  end

  defp block_view("table"), do: "table"
  defp block_view("board"), do: "board"
  defp block_view("calendar"), do: "calendar"
  defp block_view("timeline"), do: "timeline"
  defp block_view(_), do: "list"

  defp saved_or_filters(_config, _board, name) when is_binary(name),
    do: [~s|saved_view: "#{name}"|]

  defp saved_or_filters(config, board, _nil) do
    clauses =
      [
        config.q != "" && "title ~ #{config.q}",
        config.due && "due #{due_clause(config.due)}",
        config.done == "hide" && "completed=false",
        config.done == "only" && "completed=true",
        names(board.columns, config.columns) |> alternatives_clause("list"),
        config.priorities |> alternatives_clause("priority"),
        config.flags |> alternatives_clause("flag"),
        names(board.tags, config.tags) |> alternatives_clause("tag")
      ]
      |> Enum.filter(&is_binary/1)

    if clauses == [], do: [], else: ["filter: " <> Enum.join(clauses, ", ")]
  end

  defp due_clause("overdue"), do: "< today"
  defp due_clause("today"), do: "= today"
  defp due_clause("week"), do: "within 7d"
  defp due_clause("month"), do: "within 30d"
  defp due_clause("has"), do: "set"
  defp due_clause("none"), do: "not set"
  defp due_clause(_), do: "set"

  defp alternatives_clause([], _field), do: nil
  defp alternatives_clause(values, field), do: "#{field} in #{Enum.join(values, "|")}"

  # A config stores ids; a document reads better with names.
  defp names(collection, ids) do
    wanted = MapSet.new(Enum.map(ids, &to_string/1))

    collection
    |> Enum.filter(&MapSet.member?(wanted, to_string(&1.id)))
    |> Enum.map(& &1.name)
  end

  defp group_line(%Config{rows: rows}) when rows not in [nil, "none"], do: ["group: #{rows}"]
  defp group_line(_config), do: []

  defp sort_line(%Config{sort: sort, dir: dir}) when is_binary(sort),
    do: ["sort: #{sort} #{dir}"]

  defp sort_line(_config), do: []

  defp fields_line(%Config{mode: "table", fields: fields}) when fields != [],
    do: ["fields: " <> Enum.join(fields, ", ")]

  defp fields_line(_config), do: []

  ## Inline expressions -------------------------------------------------------

  @doc ~S'''
  Answers a `{{…}}` written in a sentence: "there are {{count: flag=blocked}}
  blocked cards as of {{today}}".

  Returns `{:ok, text}`, or `:error` for an expression this does not
  understand — in which case the caller leaves it exactly as written. That is
  deliberate: a template page's `{{card.title}}`, which is filled when a page
  is *made* from it, must still read as itself when the template is opened.

  Understood: `count: <filter>`, `progress: <card>`, `card:<id>.<field>`,
  `board.name`, `today`, `now`.
  '''
  @spec inline(String.t(), map) :: {:ok, String.t()} | :error
  def inline(expression, context) do
    expression = String.trim(expression)

    cond do
      expression == "today" ->
        {:ok, Date.to_iso8601(context[:today] || Date.utc_today())}

      expression == "now" ->
        {:ok, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_string()}

      expression == "board.name" ->
        case context[:board] do
          %Board{name: name} -> {:ok, name}
          _ -> :error
        end

      match = Regex.run(~r/^count:\s*(.*)$/is, expression) ->
        inline_count(Enum.at(match, 1), context)

      match = Regex.run(~r/^progress:\s*#?(\d+)$/i, expression) ->
        inline_progress(String.to_integer(Enum.at(match, 1)), context)

      match = Regex.run(~r/^card:\s*#?(\d+)\.([\w.]+)$/i, expression) ->
        inline_card_field(String.to_integer(Enum.at(match, 1)), Enum.at(match, 2), context)

      true ->
        :error
    end
  end

  defp inline_count(filter, context) do
    with {:ok, query} <- parse("view: count\nfilter: #{filter}"),
         {:ok, %{count: count}} <- run(query, context) do
      {:ok, to_string(count)}
    else
      _ -> :error
    end
  end

  defp inline_progress(card_id, context) do
    with {:ok, query} <- parse("view: progress\ncard: #{card_id}"),
         {:ok, %{done: done, total: total, percent: percent}} <- run(query, context) do
      {:ok, "#{done}/#{total} (#{percent}%)"}
    else
      _ -> :error
    end
  end

  defp inline_card_field(card_id, field, context) do
    with %Card{} = card <- Repo.get(Card, card_id),
         true <- readable_card?(card, context[:reader]) do
      case cell(Repo.preload(card, [:column, :assignee, :tags]), field) do
        "" -> {:ok, ""}
        text -> {:ok, text}
      end
    else
      _ -> :error
    end
  end
end
