defmodule Slipdock.Flow.DoingList do
  @moduledoc """
  `Slipdock.Flow.doing_list?/1` in a query (#2629): whether a list is a
  doing list by its category, else by its name, as the guide reads one
  (`SlipdockWeb.APIGuide.role/2`). A sub-board made from the Simple template
  has a "Doing" list with no category, so a check written as
  `col.category == "doing"` misses every card in progress on it.

      require Slipdock.Flow.DoingList, as: DoingList
      where: DoingList.doing?(col.category, col.name)

  It takes a category and a name rather than a list, so a move's
  `to_category` and `to_column_name` read the same way. The module has no
  aliases on purpose: requiring it adds no compile-time edge to the rest of
  the app. `test/slipdock/flow/doing_list_test.exs` holds it to
  `doing_list?/1`.
  """

  # The categories the guide reads before the name: a list in one of these
  # is a doing list only when the category is "doing".
  @categorised ~w(todo doing done dropped triage scheduled)

  # The words a name says "in progress" with (`APIGuide.role/2`).
  @words ["in progress", "doing", "wip", "started", "active"]

  @sql "(? = 'doing' OR (coalesce(?, '') NOT IN (" <>
         Enum.map_join(@categorised, ", ", &"'#{&1}'") <>
         ") AND lower(?) LIKE ANY (ARRAY[" <>
         Enum.map_join(@words, ", ", &"'%#{&1}%'") <> "])))"

  @doc "The words a list's name says it is in progress with."
  def words, do: @words

  @doc """
  A query expression: true when a list with `category` and `name` is a
  doing list. Use it inside an `Ecto.Query` (it expands to a `fragment`).
  """
  defmacro doing?(category, name) do
    sql = @sql

    quote do
      fragment(
        unquote(sql),
        unquote(category),
        unquote(category),
        unquote(name)
      )
    end
  end
end
