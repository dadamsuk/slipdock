defmodule Slipdock.ViewColumns do
  @moduledoc """
  The columns of the board views that have them — the table, the outline and
  Prioritise (#3665): which a reader may show, hide and move, and in what
  order they are drawn. The first column (the table's title, the outline's
  and Prioritise's card) is always shown, first, and isn't among them. The
  order, what is hidden and each column's width live in the view's
  `Slipdock.Swimlanes.Config` (see `Config.col_order/3`, `Config.col_widths/2`).
  """

  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table

  @views ~w(table outline prioritise)
  @outline_labels %{
    "list" => "List",
    "progress" => "Progress",
    "schedule" => "Schedule",
    "health" => "Health"
  }

  @doc "The views with columns, as their mode names."
  def views, do: @views

  @doc "The column that is always first in a view."
  def first("table"), do: "title"
  def first(_), do: "card"

  @doc "A view's movable columns as `{key, label}`, in the view's own order."
  def choosable("table", board) do
    for {key, label, _} <- Table.fields(board || %{}), key != "title", do: {key, label}
  end

  def choosable("outline", _board) do
    for key <- Config.outline_col_keys(), do: {key, Map.fetch!(@outline_labels, key)}
  end

  # Scoring fields as Prioritise draws them: the inputs, then the formulas.
  def choosable("prioritise", board) do
    {inputs, formulas} =
      Enum.split_with(Map.get(board || %{}, :fields) || [], &(&1.kind != "formula"))

    [{"priority", "Priority"}, {"votes", "Votes"}] ++
      for f <- inputs ++ formulas, do: {"f:#{f.id}", f.name}
  end

  @doc "The keys of `choosable/2`."
  def keys(view, board), do: Enum.map(choosable(view, board), &elem(&1, 0))

  @doc "A view's movable columns in the reader's order: `[{key, label, shown?}]`."
  def order(%Config{} = config, view, board) do
    labels = Map.new(choosable(view, board))

    for {key, shown?} <- Config.col_order(config, view, keys(view, board)),
        do: {key, Map.fetch!(labels, key), shown?}
  end

  @doc "The keys of a view's shown movable columns, in the reader's order."
  def shown(%Config{} = config, view, board),
    do: Config.shown_cols(config, view, keys(view, board))

  @doc "Whether `key` is a column of the view that may be resized."
  def resizable?(view, board, key), do: key == first(view) or Enum.member?(keys(view, board), key)
end
