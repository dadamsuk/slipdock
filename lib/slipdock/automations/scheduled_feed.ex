defmodule Slipdock.Automations.ScheduledFeed do
  @moduledoc """
  A board's Scheduled list (category `scheduled`, #2100) is where recurring
  agent work lands, and nobody picks from it: feed rules work it. So each
  `list_top` rule feeding the board's ready list gets a sibling feeding the
  Scheduled list, with the same runner actions, when the board has both:
  what the owner of the slipdock board added by hand as rule #47.

  A board's Housekeeping list (category `housekeeping`, #2777) gets the
  same siblings, made at the same times: generated fixes and investigations
  wait there, and its siblings are backfill feeds, which send a card only
  while their pool's ready-list and Scheduled feeds have nothing they could
  start (`Slipdock.Automations.yielding?/2`).

  `ensure/2` makes the siblings that are missing. It runs when a list is
  made or turned into the Scheduled list (`Slipdock.Boards.Columns.create_column/2`,
  `update_column/2`) and when a runner's setup makes a feed rule
  (`Slipdock.Runners.Setup`). A ready-list feed whose pools already have a
  feed on the Scheduled list is left alone, so running it again makes
  nothing.
  """

  import Ecto.Query

  alias Slipdock.Automations
  alias Slipdock.Automations.{Rule, Spec}
  alias Slipdock.Boards.{Board, Column}
  alias Slipdock.Repo

  @doc """
  Makes the missing Scheduled and Housekeeping siblings of `board`'s
  ready-list feeds. Returns `{:ok, [rule]}` with the rules it made (none on
  a board without either list or without a ready list), or
  `{:error, message}` for the first that could not be made. `:by` is who
  the rules are made by, else each sibling is made by whoever made the rule
  it copies.
  """
  def ensure(board, opts \\ [])

  def ensure(%Board{id: board_id}, opts), do: ensure(board_id, opts)

  def ensure(board_id, opts) when is_integer(board_id) do
    columns =
      Repo.all(from(c in Column, where: c.board_id == ^board_id, order_by: [asc: c.position]))

    targets =
      [Enum.find(columns, &Column.scheduled?/1), Enum.find(columns, &Column.housekeeping?/1)]
      |> Enum.reject(&is_nil/1)

    case Slipdock.Flow.ready_list(columns) do
      %Column{} = ready when targets != [] ->
        feeds = board_id |> Automations.list_rules() |> Enum.filter(&Spec.feed?(&1.spec))
        ensure_all(targets, feeds, ready, opts)

      _ ->
        {:ok, []}
    end
  end

  defp ensure_all(targets, feeds, ready, opts) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, made} ->
      case ensure_on(feeds, ready, target, opts) do
        {:ok, rules} -> {:cont, {:ok, made ++ rules}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp ensure_on(feeds, ready, target, opts) do
    covered = feeds |> Enum.filter(&feeds?(&1, target)) |> pools()

    feeds
    |> Enum.filter(&feeds?(&1, ready))
    |> Enum.reject(&MapSet.subset?(pools([&1]), covered))
    |> make_siblings(target, opts)
  end

  @doc """
  Whether `rule` feeds `column`, by the list's id or its name: how a
  sibling, or a ready-list feed, is told apart.
  """
  def feeds?(%Rule{spec: spec}, %Column{id: id, name: name}) do
    ref = spec |> get_in(["trigger", "column"]) |> to_string() |> String.trim()
    ref == Integer.to_string(id) or String.downcase(ref) == String.downcase(name)
  end

  @doc "The pools `rules`' runner actions send to, downcased."
  def pools(rules) do
    for rule <- rules,
        %{"type" => "runner", "pool" => pool} <- Spec.actions(rule.spec),
        into: MapSet.new(),
        do: String.downcase(to_string(pool))
  end

  @doc "The name of the sibling of `rule` feeding `column`: `Work Scheduled with the loop runners`."
  def sibling_name(%Rule{} = rule, %Column{name: name}) do
    case pools([rule]) |> Enum.sort() do
      [] -> String.slice("Work #{name}: #{rule.name}", 0, 120)
      pools -> String.slice("Work #{name} with the #{Enum.join(pools, ", ")} runners", 0, 120)
    end
  end

  defp make_siblings(rules, target, opts) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, made} ->
      case make_sibling(rule, target, opts) do
        {:ok, sibling} -> {:cont, {:ok, made ++ [sibling]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp make_sibling(rule, target, opts) do
    by = opts[:by] || (rule.created_by_id && Repo.get(Slipdock.Accounts.User, rule.created_by_id))
    spec = put_in(rule.spec, ["trigger", "column"], target.name)

    # A Housekeeping sibling yields to the ready list and Scheduled (#2777);
    # a Scheduled one doesn't, so a backfill flag copied from anywhere goes.
    spec =
      if Column.housekeeping?(target),
        do: put_in(spec, ["trigger", "backfill"], true),
        else: update_in(spec, ["trigger"], &Map.delete(&1, "backfill"))

    attrs = %{
      "board_id" => rule.board_id,
      "name" => sibling_name(rule, target),
      "spec" => spec,
      "scope" => rule.scope,
      "enabled" => rule.enabled
    }

    case Automations.create_rule(attrs, created_by: by) do
      {:ok, sibling} ->
        {:ok, sibling}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "the #{target.name} feed for “#{rule.name}”: #{errors(changeset)}"}
    end
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
