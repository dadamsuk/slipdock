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
