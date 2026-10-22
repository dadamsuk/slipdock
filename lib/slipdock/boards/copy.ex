defmodule Slipdock.Boards.Copy do
  @moduledoc """
  A copy of a card as it is now (W-1802): what a Duplicate makes, and what a
  recurring card's next instance is.

  Copied: title, description, priority, colour, tags, assignees, flags
  (except `blocked` and `waiting`, which were about the old one's situation),
  the estimate, and the checklist with every box unticked. A card with
  subcards gets a sub-board with the same lists, and every subcard copied the
  same way, reopened, into that sub-board's ready list in the order they had.

  Not copied: dates (a recurring series sets its own), time spent, percent
  complete, comments, attachments (a decision: files can be large, and a copy
  that silently doubles storage surprises people), links, dependencies,
  custom field values and votes.

  All or nothing: the whole copy is one transaction, and its side effects
  (automation rules, mentions) wait until it has committed. A copy the free
  tier's limit stops part-way leaves nothing behind.
  """

  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Column, Tag}
  alias Slipdock.Repo

  @dropped_flags ~w(blocked waiting)

  @doc """
  Copies `card` into `column` (nil: the card's own list).

  Options:

    * `:by` — the person making it (who mentions in the description are from).
    * `:attrs` — fields to set on the copy instead of the original's
      (string keys, as `Boards.create_card/3` takes them), e.g. dates.
    * `:at` — `:top`, `:bottom` (the default) or `:after`, straight after
      the original (only in the original's own list).
  """
  def copy_card(%Card{} = card, column \\ nil, opts \\ []) do
    column = column || Repo.get!(Column, card.column_id)

    {result, effects} =
      Slipdock.Deferred.collect(fn ->
        Repo.transaction(fn ->
          case copy_tree(card, column, opts[:attrs] || %{}, opts) do
            {:ok, copy} -> copy
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end)

    case result do
      {:ok, copy} ->
        # Let go now — or, inside a caller's own transaction that is holding
        # effects back (a recurring series' tick), handed on to it.
        Enum.each(effects, &Slipdock.Deferred.defer/1)
        place(copy, card, column, opts[:at] || :bottom)
        {:ok, Boards.get_card!(copy.id)}

      {:error, _} = error ->
        error
    end
  end

  defp copy_tree(card, column, overrides, opts) do
    card = Repo.preload(card, [:tags, :checklist_items, :sub_board], force: true)

    attrs =
      %{
        "title" => card.title,
        "description" => card.description,
        "priority" => card.priority,
        "color" => card.color,
        "border_top" => card.border_top,
        "border_right" => card.border_right,
        "border_bottom" => card.border_bottom,
        "border_left" => card.border_left,
        "flags" => card.flags -- @dropped_flags,
        "time_unit" => card.time_unit,
        "time_estimate" => card.time_estimate && "#{card.time_estimate}m",
        "assignee_ids" => Boards.assignee_ids(card)
      }
      |> Map.merge(overrides)

    with {:ok, copy} <- Boards.create_card(column, attrs, by: opts[:by]),
         {:ok, copy} <- copy_tags(copy, card, column),
         :ok <- copy_checklist(copy, card),
         :ok <- copy_sub_board(copy, card, opts) do
      {:ok, copy}
    end
  end

  # Tags belong to the root of a board tree; a copy into another tree takes
  # the tags by name, making any that tree lacks.
  defp copy_tags(copy, %Card{tags: []}, _column), do: {:ok, copy}

  defp copy_tags(copy, card, column) do
    target_root = column.board_id |> then(&Repo.get!(Board, &1)) |> Board.root_id()

    tags =
      Enum.map(card.tags, fn
        %Tag{board_id: ^target_root} = tag -> tag
        tag -> tag_in(target_root, tag)
      end)

    Boards.set_card_tags(copy, tags)
  end

  defp tag_in(root_id, %Tag{name: name, color: color}) do
    case Repo.one(from(t in Tag, where: t.board_id == ^root_id and t.name == ^name)) do
      nil ->
        {:ok, tag} =
          Boards.create_tag(Repo.get!(Board, root_id), %{"name" => name, "color" => color})

        tag

      tag ->
        tag
    end
  end

  defp copy_checklist(copy, card) do
    Enum.each(card.checklist_items, &Boards.add_checklist_item(copy, &1.text, log: false))
    :ok
  end

  defp copy_sub_board(_copy, %Card{sub_board: nil}, _opts), do: :ok

  defp copy_sub_board(copy, %Card{sub_board: source}, opts) do
    parent = Repo.get!(Board, copy.board_id)
    columns = Boards.template_attrs_from_board(source)["columns"]

    with {:ok, board} <-
           Boards.create_board(
             %{
               "name" => Board.name_for_card(copy.title),
               "color" => source.color,
               "simple" => source.simple
             },
             columns: columns,
             parent_card_id: copy.id,
             root_id: Board.root_id(parent),
             owner_id: parent.owner_id
           ) do
      board = Boards.get_board!(board.id)
      ready = SlipdockWeb.APIGuide.list_roles(board.columns).ready || hd(board.columns)

      source.id
      |> subcards()
      |> Enum.reduce_while(:ok, fn sub, :ok ->
        case copy_tree(sub, ready, %{}, opts) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # The subcards to carry over, in the order a reader sees them: list by
  # list, top to bottom. Archived cards and sprint stand-ins stay behind.
  defp subcards(board_id) do
    from(c in Card,
      join: col in Column,
      on: col.id == c.column_id,
      where: c.board_id == ^board_id and is_nil(c.archived_at) and is_nil(c.stand_in_for_id),
      order_by: [asc: col.position, asc: c.position, asc: c.id]
    )
    |> Repo.all()
  end

  defp place(_copy, _card, _column, :bottom), do: :ok

  defp place(copy, _card, column, :top), do: Boards.move_card_to_index(copy, column, :top)

  defp place(copy, %Card{column_id: column_id} = card, %Column{id: column_id} = column, :after) do
    index =
      column_id
      |> Boards.active_items()
      |> List.delete({:card, copy.id})
      |> Enum.find_index(&(&1 == {:card, card.id}))

    if index, do: Boards.move_card_to_index(copy, column, index + 1), else: :ok
  end

  defp place(_copy, _card, _column, :after), do: :ok
end
