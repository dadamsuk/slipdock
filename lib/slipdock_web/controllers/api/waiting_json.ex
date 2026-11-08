defmodule SlipdockWeb.API.WaitingJSON do
  @moduledoc """
  `waiting_on_me` (#2095): what in a tree waits on the caller, as REST and
  MCP `get_card` / `get_board` give it, and the CLI prints.

  Every shape is `%{count:, cards:, on_others:, line:}`: `count` the items
  on the caller, `cards` those items, each exactly as `GET /api/work` gives
  it (`SlipdockWeb.API.WorkController.item/1`, the same `Slipdock.Work`
  item) plus `short`, its reason in a few words; `on_others` how many open
  waits in the tree are on someone else by name; `line` the glance line the
  tile shows (`Slipdock.Work.Tree.glance/1`), nil when nothing waits.

  On a card it is the card's sub-board tree (an epic's; zeros on a card
  with no subcards). On a board, the board itself carries its whole tree's,
  and each epic in its lists carries its own.
  """

  alias Slipdock.Work
  alias Slipdock.Work.Tree
  alias SlipdockWeb.API.WorkController

  @doc "One epic's or one tree's entry: `%{mine: items, others: waits}`."
  def entry(%{mine: mine, others: others} = entry) do
    %{
      count: length(mine),
      cards: Enum.map(mine, &item/1),
      on_others: length(others),
      line: Tree.glance(entry)
    }
  end

  @doc "A whole tree (`Tree.for_board/3` or `Tree.for_card/3`)."
  def tree(%Tree{items: items, others: others}), do: entry(%{mine: items, others: others})

  @doc "`waiting_on_me` for `card`, the caller's, read through its sub-board."
  def for_card(user, card), do: user |> Tree.for_card(card) |> tree()

  @doc """
  Puts `waiting_on_me` on each card in `cards` (JSON maps with `id`) that
  has subcards, as `subcards?` says, from `tree` (the board's).
  """
  def put_on_cards(cards, %Tree{} = tree, subcards?) do
    Enum.map(cards, fn c ->
      if subcards?.(c), do: Map.put(c, :waiting_on_me, entry(Tree.of(tree, c.id))), else: c
    end)
  end

  defp item(i) do
    i
    |> Map.put(:path, i[:path] || Work.path(i.card))
    |> WorkController.item()
    |> Map.put(:short, Tree.short(i))
  end
end
