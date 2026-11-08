defmodule Slipdock.Automations.ScheduledFeed do
  @moduledoc """
  A board's Scheduled list (category `scheduled`, #2100) is where recurring
  agent work lands, and nobody picks from it: feed rules work it. So each
  `list_top` rule feeding the board's ready list gets a sibling feeding the
  Scheduled list, with the same runner actions, when the board has both:
  what the owner of the slipdock board added by hand as rule #47.

  `ensure/2` makes the siblings that are missing. It runs when a list is
  made or turned into the Scheduled list (`Slipdock.Boards.create_column/2`,
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
  Makes the missing Scheduled siblings of `board`'s ready-list feeds.
  Returns `{:ok, [rule]}` with the rules it made (none on a board without
  a Scheduled list or a ready list), or `{:error, message}` for the first
  that could not be made. `:by` is who the rules are made by, else each
  sibling is made by whoever made the rule it copies.
  """
  def ensure(board, opts \\ [])

  def ensure(%Board{id: board_id}, opts), do: ensure(board_id, opts)

  def ensure(board_id, opts) when is_integer(board_id) do
    columns =
      Repo.all(from(c in Column, where: c.board_id == ^board_id, order_by: [asc: c.position]))

    with %Column{} = scheduled <- Enum.find(columns, &Column.scheduled?/1),
         %Column{} = ready <- Slipdock.Flow.ready_list(columns) do
      feeds = board_id |> Automations.list_rules() |> Enum.filter(&Spec.feed?(&1.spec))
      covered = feeds |> Enum.filter(&feeds?(&1, scheduled)) |> pools()

      feeds
      |> Enum.filter(&feeds?(&1, ready))
      |> Enum.reject(&MapSet.subset?(pools([&1]), covered))
      |> make_siblings(scheduled, opts)
    else
      _ -> {:ok, []}
    end
  end

  @doc "The name of the sibling of `rule` feeding `column`: `Work Scheduled with the loop runners`."
  def sibling_name(%Rule{} = rule, %Column{name: name}) do
    case pools([rule]) |> Enum.sort() do
      [] -> String.slice("Work #{name}: #{rule.name}", 0, 120)
      pools -> String.slice("Work #{name} with the #{Enum.join(pools, ", ")} runners", 0, 120)
    end
  end

  defp make_siblings(rules, scheduled, opts) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, made} ->
      case make_sibling(rule, scheduled, opts) do
        {:ok, sibling} -> {:cont, {:ok, made ++ [sibling]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp make_sibling(rule, scheduled, opts) do
    by = opts[:by] || (rule.created_by_id && Repo.get(Slipdock.Accounts.User, rule.created_by_id))
    spec = put_in(rule.spec, ["trigger", "column"], scheduled.name)

    attrs = %{
      "board_id" => rule.board_id,
      "name" => sibling_name(rule, scheduled),
      "spec" => spec,
      "scope" => rule.scope,
      "enabled" => rule.enabled
    }

    case Automations.create_rule(attrs, created_by: by) do
      {:ok, sibling} ->
        {:ok, sibling}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "the Scheduled feed for “#{rule.name}”: #{errors(changeset)}"}
    end
  end

  # Whether the feed's trigger names `column`, by id or by name.
  defp feeds?(%Rule{spec: spec}, %Column{id: id, name: name}) do
    ref = spec |> get_in(["trigger", "column"]) |> to_string() |> String.trim()
    ref == Integer.to_string(id) or String.downcase(ref) == String.downcase(name)
  end

  defp pools(rules) do
    for rule <- rules,
        %{"type" => "runner", "pool" => pool} <- Spec.actions(rule.spec),
        into: MapSet.new(),
        do: String.downcase(to_string(pool))
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
