defmodule Slipdock.Boards.Checklists do
  @moduledoc """
  Checklist items on a card or a wiki page.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.ChecklistItem
  alias Slipdock.Repo

  ## Checklist

  # Every change to a checklist is a line in the activity log. One that does
  # several at once (an agent's `update_card`, a rule, the assistant) passes
  # `log: false` to each and then `log_checklist/2` once, so one call is one
  # line rather than one per tick box.

  @doc "Adds a tick box to a card or to a wiki page. `log: false` leaves it out of the activity log."
  def add_checklist_item(owner, text, opts \\ []) do
    position =
      Boards.Shared.next_position(where(ChecklistItem, ^Boards.Shared.owned_clause(owner)))

    %ChecklistItem{position: position}
    |> struct!(Boards.Shared.owned_by(owner))
    |> ChecklistItem.changeset(%{"text" => text})
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn _ ->
      Boards.Shared.notify_owned(owner)
      if Keyword.get(opts, :log, true), do: log_checklist(owner, added: 1)
    end)
  end

  @doc "A tick box on `owner` (a card or a page), or nil if it is not one of its own."
  def get_checklist_item(owner, id), do: Boards.Shared.get_owned(ChecklistItem, owner, id)

  @doc "Ticks a tick box, or unticks a ticked one. `log: false` as for `add_checklist_item/3`."
  def toggle_checklist_item(item, opts \\ [])

  def toggle_checklist_item(%ChecklistItem{} = item, opts) do
    item
    |> Ecto.Changeset.change(done: !item.done)
    |> Repo.update()
    |> Boards.Shared.tap_ok(fn updated ->
      owner = Boards.Shared.owner_of(item)
      Boards.Shared.notify_owned(owner)

      if Keyword.get(opts, :log, true),
        do: log_checklist(owner, [{if(updated.done, do: :ticked, else: :unticked), 1}])
    end)
  end

  def toggle_checklist_item(id, opts),
    do: toggle_checklist_item(Repo.get!(ChecklistItem, id), opts)

  @doc "Removes a tick box. `log: false` as for `add_checklist_item/3`."
  def delete_checklist_item(item, opts \\ [])

  def delete_checklist_item(%ChecklistItem{} = item, opts) do
    Repo.delete(item)
    |> Boards.Shared.tap_ok(fn _ ->
      owner = Boards.Shared.owner_of(item)
      Boards.Shared.notify_owned(owner)
      if Keyword.get(opts, :log, true), do: log_checklist(owner, removed: 1)
    end)
  end

  def delete_checklist_item(id, opts),
    do: delete_checklist_item(Repo.get!(ChecklistItem, id), opts)

  @doc """
  Moves a tick box so that it sits directly before `before_id`, another tick
  box on the same card or page, or last when `before_id` is nil (or `""`) (#1752).
  Every item of that checklist is renumbered `0..n-1`.

  `{:ok, items}` gives the checklist in its new order; `{:error, :not_found}`
  when `before_id` is not one of the same card's (or page's) items. Moving
  an item before itself leaves the order as it was. A new order is not a
  line in the activity log: nothing was added, ticked or removed.
  """
  def move_checklist_item(%ChecklistItem{} = item, before_id) do
    owner = Boards.Shared.owner_of(item)

    ids =
      Repo.all(
        from(i in ChecklistItem,
          where: ^Boards.Shared.owned_clause(owner),
          order_by: [asc: i.position, asc: i.id],
          select: i.id
        )
      )

    last? = Enum.member?([nil, ""], before_id)
    before = if last?, do: nil, else: Boards.Shared.to_id(before_id)

    cond do
      not last? and not Enum.member?(ids, before) ->
        {:error, :not_found}

      before == item.id ->
        {:ok, checklist_of(owner)}

      true ->
        ids
        |> List.delete(item.id)
        |> Boards.Columns.insert_before(item.id, before)
        |> Enum.with_index()
        |> set_positions()

        Boards.Shared.notify_owned(owner)
        {:ok, checklist_of(owner)}
    end
  end

  defp set_positions(order) do
    Repo.transaction(fn ->
      for {id, i} <- order do
        from(c in ChecklistItem, where: c.id == ^id and c.position != ^i)
        |> Repo.update_all(set: [position: i])
      end
    end)
  end

  defp checklist_of(owner),
    do:
      Repo.all(
        from(i in ChecklistItem,
          where: ^Boards.Shared.owned_clause(owner),
          order_by: [asc: i.position, asc: i.id]
        )
      )

  @doc """
  One activity line for what was done to `owner`'s checklist: `changes` counts
  any of `added`, `ticked`, `unticked` and `removed`. Nothing is logged when
  every count is zero.
  """
  def log_checklist(owner, changes) do
    case for verb <- ~w(added ticked unticked removed)a,
             (n = changes[verb] || 0) > 0,
             do: {verb, n} do
      [] ->
        :ok

      done ->
        with {:ok, _} <-
               Boards.Shared.log_owned(owner, "checklist", checklist_message(done, owner.title)),
             do: :ok
    end
  end

  defp checklist_message([{verb, n}], title) do
    on = %{added: "to", removed: "from"}[verb] || "on"
    "#{verb} #{items(n)} #{on} “#{title}”"
  end

  defp checklist_message(done, title) do
    "changed the checklist on “#{title}”: " <>
      Enum.map_join(done, ", ", fn {v, n} -> "#{v} #{n}" end)
  end

  defp items(1), do: "a checklist item"
  defp items(n), do: "#{n} checklist items"
end
