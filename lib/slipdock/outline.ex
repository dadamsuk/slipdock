defmodule Slipdock.Outline do
  @moduledoc """
  The outline view: a board's cards as a collapsible tree, each card with
  its subcards beneath it (from `Slipdock.Rollup`), down to a chosen depth.
  Collapsed to one level it is the roadmap; fully expanded it is the task
  list — the same tree read at different resolutions.

  Filters and sorting come from the swimlane `Config`, as in every other
  view. A card that fails the filters is still shown, muted, when something
  beneath it matches, so a match keeps its context.

  Everything here is pure; `Slipdock.Rollup` does the loading.
  """

  alias Slipdock.Rollup
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config

  @max_depth 9
  @per_page 250

  @type entry :: %{
          card: Slipdock.Boards.Card.t(),
          stats: Rollup.stats(),
          children: [entry],
          level: non_neg_integer,
          match: boolean,
          list: String.t() | nil,
          sub_board_id: integer | nil,
          more: boolean
        }

  @doc "The deepest depth a config may ask for."
  def max_depth, do: @max_depth

  @doc "The depth choices as `{value, label}`, up to `levels` (at least `at_least`)."
  def depths(levels, at_least \\ 1) do
    top = levels |> max(at_least) |> max(1) |> min(@max_depth)

    [{"all", "All levels"}] ++
      for n <- 1..top//1, do: {to_string(n), "#{n} #{if n == 1, do: "level", else: "levels"}"}
  end

  @doc "The numeric depth a config asks for, or `:all`."
  def depth(%Config{depth: "all"}), do: :all
  def depth(%Config{depth: d}), do: String.to_integer(d)

  @doc """
  Builds the outline of `board`. Returns a map with:

    * `:nodes` – the tree (see `t:entry/0`), siblings sorted per the config
    * `:shown` / `:hidden` – cards that pass / fail the filters, in the
      levels shown
    * `:levels` – how many levels the board has beneath it
    * `:depth` – the depth shown (`:all` or an integer)
    * `:done` / `:total` – leaves done / in all, across the top-level cards
  """
  def build(board, %Rollup{} = rollup, %Config{} = config, today \\ Date.utc_today()) do
    depth = depth(config)
    tree = Rollup.tree(rollup, board.id, depth)
    {nodes, shown, total} = prune(tree, rollup, config, today)

    %{
      nodes: nodes,
      shown: shown,
      hidden: total - shown,
      levels: Rollup.levels(rollup, board.id),
      depth: depth,
      done: nodes |> Enum.map(& &1.stats.done) |> Enum.sum(),
      total: nodes |> Enum.map(& &1.stats.total) |> Enum.sum()
    }
  end

  @doc "How many rows one page of the outline holds at most."
  def per_page, do: @per_page

  @doc """
  One page of an outline, at most `:per_page` (250) rows. A row is a card
  shown: a collapsed card (its key, `card-<id>`, in `:collapsed`) is one row
  however much is beneath it. Each top-level card's subtree is kept on one
  page where it fits, so a page ends between top-level cards; only a subtree
  bigger than a page is split, and the page that carries on from it starts
  with the cards above its first row again, marked `continued: true`, as
  context (they count towards the page). `page` counts from 1 and is held
  between 1 and the last page, so a page past the end (after a filter
  narrowed the list) shows the last. Returns:

    * `:nodes` – this page's tree, shaped as `build/4`'s
    * `:page` / `:pages` – this page and how many there are (at least 1)
    * `:from` / `:to` – the 1-based positions of its first and last row,
      context rows aside (0 and 0 on an empty outline)
    * `:count` – rows in all
  """
  def page(%{nodes: nodes}, page, opts \\ []) when is_integer(page) do
    per_page = Keyword.get(opts, :per_page, @per_page)
    collapsed = Keyword.get(opts, :collapsed, MapSet.new())

    {pages, count} = nodes |> pack(collapsed, per_page) |> number()
    page = page |> max(1) |> min(length(pages))
    rows = Enum.at(pages, page - 1)
    positions = for %{at: at} when is_integer(at) <- rows, do: at

    %{
      nodes: tree(rows),
      page: page,
      pages: length(pages),
      from: List.first(positions, 0),
      to: List.last(positions, 0),
      count: count
    }
  end

  # Pages of flat rows, in order. A top-level subtree goes on the current
  # page if it fits, else starts the next; one bigger than a page is split.
  defp pack(nodes, collapsed, per_page) do
    {done, current, _} =
      Enum.reduce(nodes, {[], [], 0}, fn top, {done, current, used} ->
        rows = flatten(top, [], collapsed)
        size = length(rows)

        cond do
          used + size <= per_page ->
            {done, [rows | current], used + size}

          size <= per_page ->
            {close(done, current), [rows], size}

          true ->
            {full, [last]} = rows |> split(per_page, []) |> Enum.split(-1)
            {Enum.reverse(full, close(done, current)), [last], length(last)}
        end
      end)

    case close(done, current) |> Enum.reverse() do
      [] -> [[]]
      pages -> pages
    end
  end

  defp close(done, []), do: done
  defp close(done, current), do: [current |> Enum.reverse() |> Enum.concat() | done]

  # A card and the rows shown beneath it, each knowing the rows above it.
  defp flatten(node, path, collapsed) do
    open = node.children != [] and not MapSet.member?(collapsed, "card-#{node.card.id}")
    row = %{node: node, path: path, open: open, context: false}

    if open,
      do: [row | Enum.flat_map(node.children, &flatten(&1, path ++ [row], collapsed))],
      else: [row]
  end

  # Cuts a subtree's rows into pages; each page after the first repeats the
  # cards above its first row as context, within the page's rows.
  defp split([], _per_page, acc), do: Enum.reverse(acc)

  defp split([first | _] = rows, per_page, acc) do
    context = if acc == [], do: [], else: Enum.map(first.path, &%{&1 | context: true})
    {chunk, rest} = Enum.split(rows, max(per_page - length(context), 1))
    split(rest, per_page, [context ++ chunk | acc])
  end

  # Gives each real row its 1-based position across the pages.
  defp number(pages) do
    Enum.map_reduce(pages, 0, fn rows, n ->
      Enum.map_reduce(rows, n, fn
        %{context: true} = row, n -> {Map.put(row, :at, nil), n}
        row, n -> {Map.put(row, :at, n + 1), n + 1}
      end)
    end)
  end

  # Back from rows in order to the nested nodes the view draws. An open card
  # gets only the children on this page; a collapsed one keeps its own.
  defp tree([]), do: []

  defp tree([row | rest]) do
    depth = length(row.path)
    {beneath, after_it} = Enum.split_while(rest, &(length(&1.path) > depth))
    node = if row.open, do: %{row.node | children: tree(beneath)}, else: row.node
    [Map.put(node, :continued, row.context) | tree(after_it)]
  end

  # Keeps matching nodes and the ancestors of matches; counts matches and
  # visited nodes. Siblings are sorted per the config.
  defp prune(nodes, rollup, config, today) do
    {kept, {shown, total}} =
      nodes
      |> sort(rollup, config)
      |> Enum.map_reduce({0, 0}, fn node, {shown, total} ->
        {children, kid_shown, kid_total} = prune(node.children, rollup, config, today)
        match = matches?(node.card, node.stats, config, today)
        shown = shown + kid_shown + if(match, do: 1, else: 0)
        total = total + kid_total + 1

        node =
          node
          |> Map.merge(%{
            children: children,
            match: match,
            list: list_name(rollup, node.card),
            sub_board_id: Map.get(rollup.sub_board, node.card.id),
            more: node.children == [] and node.stats.children > 0
          })

        {if(match or children != [], do: node, else: nil), {shown, total}}
      end)

    {Enum.reject(kept, &is_nil/1), shown, total}
  end

  defp sort([], _rollup, _config), do: []

  defp sort([first | _] = nodes, rollup, config) do
    col_pos =
      case Rollup.board(rollup, first.card.board_id) do
        %{columns: cols} when is_list(cols) -> Map.new(cols, &{&1.id, &1.position})
        _ -> %{}
      end

    by_id = Map.new(nodes, &{&1.card.id, &1})

    nodes
    |> Enum.map(& &1.card)
    |> Swimlanes.sort(config, col_pos)
    |> Enum.map(&Map.fetch!(by_id, &1.id))
  end

  # The rollup's light cards carry no dependency lists, so the dependency
  # filter reads the rolled-up blocked flag instead.
  defp matches?(card, stats, config, today) do
    light = %{card | blocked_by: [], blocks: []}
    Swimlanes.matches?(light, %{config | deps: nil}, today) and deps?(config.deps, stats)
  end

  defp deps?("blocked", stats), do: stats.blocked
  defp deps?("ready", stats), do: not stats.blocked
  defp deps?(_, _), do: true

  defp list_name(rollup, card) do
    with %{columns: cols} when is_list(cols) <- Rollup.board(rollup, card.board_id),
         %{name: name} <- Enum.find(cols, &(&1.id == card.column_id)) do
      name
    else
      _ -> nil
    end
  end
end
