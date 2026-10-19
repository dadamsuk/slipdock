defmodule Slipdock.BulkEdit do
  @moduledoc """
  One change made to several cards at once: what the board's select mode
  (#592) does with the cards picked out on it.

  Every card is named by id from a client, so each is checked against the
  board it is being changed from — a card on anybody else's board, an
  archived card or a stand-in is left out, not changed — and the reader
  must be able to write to that board. A move to another board also needs
  write access there.

  The cards are changed one by one, through the same `Slipdock.Boards`
  functions a single card's edit uses, so the history, the automations and
  the search index see each change as they would see it made by hand. One
  card refusing (a quota, a validation) does not stop the rest: the result
  says how many changed and which did not, and why.

  Actions:

    * `:archive`, `:delete`, `:complete`, `:reopen`
    * `{:add_tag, tag_id}`, `{:remove_tag, tag_id}` — a tag of the board's tree
    * `{:priority, p}` — one of `Slipdock.Boards.Card.priorities/0`
    * `{:add_flag, f}`, `{:remove_flag, f}` — one of `Slipdock.Boards.Card.flags/0`
    * `:assign_me`, `:unassign`
    * `{:move, column_id}` — a list on this board, or on another board the
      reader can write to (see `destinations/2`)
  """

  import Ecto.Query

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.Boards.{Board, Card, Column}

  @type result :: %{changed: non_neg_integer(), failed: [{Card.t(), String.t()}]}

  @doc """
  Applies `action` to the cards `ids` on `board`, as `user`.

  Returns `{:ok, %{changed: n, failed: [{card, reason}]}}`, or
  `{:error, reason}` when nothing could be tried at all: no access, no cards,
  an action it does not know, a tag, priority, flag or list that is not one.
  """
  @spec apply(Slipdock.Accounts.User.t(), Board.t(), [term()], term()) ::
          {:ok, result()} | {:error, String.t()}
  def apply(user, %Board{} = board, ids, action) do
    with :ok <- writable(user, board),
         {:ok, cards} <- cards(board, ids),
         {:ok, change} <- resolve(user, board, action) do
      {:ok, Enum.reduce(cards, %{changed: 0, failed: []}, &tally(&1, change, &2))}
    end
  end

  @doc """
  Where `user` can move cards from `board`: this board's lists first, then
  every other top-level board they can write to, as `[{board, [column]}]`.
  """
  def destinations(user, %Board{} = board) do
    others =
      user
      |> Access.list_boards()
      |> Enum.filter(
        &(&1.id != board.id and Access.can_write?(Access.board_permission(user, &1)))
      )

    boards = [board | others]

    columns =
      from(c in Column, where: c.board_id in ^Enum.map(boards, & &1.id), order_by: c.position)
      |> Repo.all()
      |> Enum.group_by(& &1.board_id)

    for b <- boards, cols = Map.get(columns, b.id, []), cols != [], do: {b, cols}
  end

  @doc """
  An action as the select mode's bar sends it — `archive`, `tag:7`,
  `priority:high`, `move:12` — as `apply/4` takes it, with the verb its
  flash uses. `:error` for anything else.
  """
  def parse_action(text) when is_binary(text) do
    case String.split(text, ":", parts: 2) do
      ["archive"] -> {:ok, :archive, "Archived"}
      ["delete"] -> {:ok, :delete, "Deleted"}
      ["complete"] -> {:ok, :complete, "Completed"}
      ["reopen"] -> {:ok, :reopen, "Reopened"}
      ["assign_me"] -> {:ok, :assign_me, "Assigned you to"}
      ["unassign"] -> {:ok, :unassign, "Unassigned"}
      ["tag", id] -> {:ok, {:add_tag, id}, "Tagged"}
      ["untag", id] -> {:ok, {:remove_tag, id}, "Untagged"}
      ["priority", p] -> {:ok, {:priority, p}, "Set the priority of"}
      ["flag", f] -> {:ok, {:add_flag, f}, "Flagged"}
      ["unflag", f] -> {:ok, {:remove_flag, f}, "Unflagged"}
      ["move", id] -> {:ok, {:move, id}, "Moved"}
      _ -> :error
    end
  end

  def parse_action(_), do: :error

  @doc "A sentence saying what happened, for a flash."
  def describe({:ok, %{changed: n, failed: []}}, verb), do: "#{verb} #{cards_text(n)}."

  def describe({:ok, %{changed: n, failed: failed}}, verb) do
    reasons = failed |> Enum.map(fn {c, why} -> "“#{c.title}”: #{why}" end) |> Enum.join("; ")
    "#{verb} #{cards_text(n)}; #{length(failed)} couldn't be: #{reasons}"
  end

  def describe({:error, reason}, _verb), do: reason

  defp cards_text(1), do: "1 card"
  defp cards_text(n), do: "#{n} cards"

  defp writable(user, board) do
    if Access.can_write?(Access.board_permission(user, board)),
      do: :ok,
      else: {:error, "You have read-only access to this board."}
  end

  defp cards(board, ids) do
    ids = ids |> List.wrap() |> Enum.map(&to_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    cards =
      from(c in Card,
        where:
          c.id in ^ids and c.board_id == ^board.id and is_nil(c.archived_at) and
            is_nil(c.stand_in_for_id),
        order_by: [asc: c.position]
      )
      |> Repo.all()

    if cards == [], do: {:error, "No cards are selected."}, else: {:ok, cards}
  end

  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  # The action, checked once and turned into a function of one card, so a
  # bad tag or list is refused before any card has changed.
  defp resolve(_user, _board, :archive), do: {:ok, &Boards.archive_card/1}
  defp resolve(_user, _board, :delete), do: {:ok, &Boards.delete_card/1}

  defp resolve(_user, _board, :complete),
    do: {:ok, &Boards.update_card(&1, %{"completed" => true})}

  defp resolve(_user, _board, :reopen),
    do: {:ok, &Boards.update_card(&1, %{"completed" => false})}

  defp resolve(user, _board, :assign_me),
    do: {:ok, &Boards.update_card(&1, %{"add_assignee_ids" => [user.id]})}

  defp resolve(_user, _board, :unassign),
    do: {:ok, &Boards.update_card(&1, %{"assignee_ids" => []})}

  defp resolve(_user, _board, {:priority, p}) do
    if p in Card.priorities(),
      do: {:ok, &Boards.update_card(&1, %{"priority" => p})},
      else: {:error, "That isn't a priority."}
  end

  defp resolve(_user, _board, {op, flag}) when op in [:add_flag, :remove_flag] do
    if flag in Card.flags() do
      {:ok,
       fn card ->
         flags =
           if op == :add_flag,
             do: Enum.uniq(card.flags ++ [flag]),
             else: List.delete(card.flags, flag)

         Boards.update_card(card, %{"flags" => flags})
       end}
    else
      {:error, "That isn't a flag."}
    end
  end

  defp resolve(_user, board, {op, tag_id}) when op in [:add_tag, :remove_tag] do
    case Enum.find(Boards.list_tags(Board.root_id(board)), &(&1.id == to_id(tag_id))) do
      nil ->
        {:error, "That tag isn't on this board."}

      tag ->
        {:ok,
         fn card ->
           card = Repo.preload(card, :tags)
           has? = Enum.any?(card.tags, &(&1.id == tag.id))

           cond do
             op == :add_tag and not has? ->
               Boards.set_card_tags(card, card.tags ++ [tag])

             op == :remove_tag and has? ->
               Boards.set_card_tags(card, Enum.reject(card.tags, &(&1.id == tag.id)))

             true ->
               {:ok, card}
           end
         end}
    end
  end

  defp resolve(user, board, {:move, column_id}) do
    with %Column{} = column <- column_id |> to_id() |> then(&(&1 && Repo.get(Column, &1))),
         true <-
           column.board_id == board.id or
             writable(user, Boards.get_board!(column.board_id)) == :ok do
      {:ok,
       fn card ->
         if column.board_id == card.board_id,
           do: Boards.move_card(card.id, column.id, nil, actor: Slipdock.Actor.web(user)),
           else: Boards.move_card_to_board(card, column, actor: Slipdock.Actor.web(user))
       end}
    else
      _ -> {:error, "You can't move cards to that list."}
    end
  end

  defp resolve(_user, _board, _action), do: {:error, "That isn't something a selection can do."}

  defp tally(card, change, acc) do
    case change.(card) do
      :ok -> %{acc | changed: acc.changed + 1}
      {:ok, _} -> %{acc | changed: acc.changed + 1}
      {:error, reason} -> %{acc | failed: acc.failed ++ [{card, reason_text(reason)}]}
    end
  end

  defp reason_text(reason) when is_binary(reason), do: reason

  defp reason_text(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp reason_text(%{message: message}) when is_binary(message), do: message
  defp reason_text(reason), do: inspect(reason)
end
