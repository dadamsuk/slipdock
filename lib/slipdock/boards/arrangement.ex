defmodule Slipdock.Boards.Arrangement do
  @moduledoc """
  Archiving boards and putting them back, and the order a person's boards
  are listed in: the home page's ranks, a board placed or nudged, and when
  something last happened on each.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.Activity
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.BoardOrder
  alias Slipdock.Multiboard.Saved, as: SavedMultiboard
  alias Slipdock.Quota
  alias Slipdock.Repo
  alias Slipdock.Vaults.Vault
  alias Slipdock.Wiki.Changes

  ## Archiving and ordering boards ---------------------------------------------

  @doc """
  Puts a board away. It drops off the board index, the switcher, quick add and
  the list of boards a card can move to, but nothing on it is deleted: the
  link still opens it, and its cards still turn up in search.

  Only root boards can be archived — a sub-board belongs to the card it hangs
  off, and goes away with it.
  """
  def archive_board(%Board{} = board) do
    cond do
      Board.sub_board?(board) -> {:error, :sub_board}
      Board.archived?(board) -> {:ok, board}
      true -> set_archived(board, DateTime.utc_now(:second), "archived")
    end
  end

  @doc """
  Brings an archived board back to the index it came off — if its owner has
  room for another board, since an archived one is not counted.
  """
  def unarchive_board(%Board{} = board) do
    if Board.archived?(board), do: set_archived(board, nil, "restored"), else: {:ok, board}
  end

  defp set_archived(%Board{} = board, at, verb) do
    board
    |> Ecto.Changeset.change(archived_at: at)
    |> then(&if(is_nil(at), do: Quota.enforce_owner(&1, board.owner_id, :boards), else: &1))
    |> Repo.update()
    |> Boards.Shared.tap_ok(fn b ->
      Boards.ActivityLog.log(Repo, b.id, nil, "board", "#{verb} board “#{b.name}”")
      Changes.record(b.id, "board", b.id, verb)
      Boards.PubSub.broadcast(b.id)
    end)
  end

  @doc """
  Where `user` has put each board on their own index, as a map of board id to
  position. Boards they have never placed are not in it.
  """
  def board_order(%User{} = user) do
    from(o in BoardOrder, where: o.user_id == ^user.id, select: {o.board_id, o.position})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Each of `boards` ranked as `user`'s home page lists boards sorted by hand,
  as a map of board id to a rank from 0: their Knowledge Base first, which
  the home page doesn't list (W-2201), then the boards they have placed, by
  their place, then the rest, oldest first. The wiki's tree follows it at
  its top, and the sync listing sends it, so every client agrees.
  """
  def home_ranks(%User{} = user, boards) do
    order = board_order(user)

    boards
    |> Enum.sort_by(fn board ->
      case {Board.wiki?(board), order[board.id]} do
        {true, _} -> {0, 0, made_key(board)}
        {false, nil} -> {2, 0, made_key(board)}
        {false, position} -> {1, position, {0, 0, board.id}}
      end
    end)
    |> Enum.with_index()
    |> Map.new(fn {board, rank} -> {board.id, rank} end)
  end

  @doc """
  Sets the order `user` lists boards in: `ids` is every board they can see, in
  the order they want them. The order is theirs alone — nobody else's index
  moves — and a board left out of `ids` loses its place and falls back to the
  end, where a board nobody has placed sits.

  Their vaults are listed among their boards on the home page, so `ids` may
  name them too — as `%Vault{}`s, `{:vault, id}` or `"vault-<id>"` — and each
  takes its place among the boards; a vault left out loses its place. An
  order naming no vault at all (one set from the command line, say) leaves
  each placed vault behind as many boards as it was behind before. Their
  saved multiboards (#1482) are listed there too, as
  `%Slipdock.Multiboard.Saved{}`s, `{:multiboard, id}` or
  `"multiboard-<id>"`, and are kept the same way.

  Ids of boards the user cannot see, and vaults or multiboards that are not
  theirs, are ignored.
  """
  def reorder_boards(%User{} = user, ids) do
    keys = user |> keep_unnamed(Enum.map(ids, &order_key/1))

    board_ids = for {:board, id} <- keys, do: id

    visible =
      from(b in Board, where: b.id in ^board_ids, select: b.id)
      |> Repo.all()
      |> MapSet.new()

    own_vaults =
      from(v in Vault, where: v.user_id == ^user.id, select: v.id)
      |> Repo.all()
      |> MapSet.new()

    own_multiboards =
      from(m in SavedMultiboard, where: m.user_id == ^user.id, select: m.id)
      |> Repo.all()
      |> MapSet.new()

    placed =
      keys
      |> Enum.uniq()
      |> Enum.filter(fn
        {:board, id} -> MapSet.member?(visible, id)
        {:vault, id} -> MapSet.member?(own_vaults, id)
        {:multiboard, id} -> MapSet.member?(own_multiboards, id)
      end)
      |> Enum.with_index()

    now = DateTime.utc_now(:second)

    rows =
      for {{:board, id}, i} <- placed,
          do: %{user_id: user.id, board_id: id, position: i, inserted_at: now, updated_at: now}

    Repo.transaction(fn ->
      Repo.delete_all(from(o in BoardOrder, where: o.user_id == ^user.id))
      Repo.insert_all(BoardOrder, rows)
      Repo.update_all(from(v in Vault, where: v.user_id == ^user.id), set: [position: nil])

      for {{:vault, id}, i} <- placed,
          do: Repo.update_all(from(v in Vault, where: v.id == ^id), set: [position: i])

      Repo.update_all(from(m in SavedMultiboard, where: m.user_id == ^user.id),
        set: [position: nil]
      )

      for {{:multiboard, id}, i} <- placed,
          do: Repo.update_all(from(m in SavedMultiboard, where: m.id == ^id), set: [position: i])
    end)

    # The order is this person's alone.
    Boards.PubSub.notify_users_boards_changed([user.id])
    :ok
  end

  # Boards, vaults and saved multiboards share the one order, told apart by
  # a tag.
  defp order_key(%Vault{id: id}), do: {:vault, id}
  defp order_key(%SavedMultiboard{id: id}), do: {:multiboard, id}
  defp order_key({:vault, id}), do: {:vault, Boards.Shared.to_id(id)}
  defp order_key({:multiboard, id}), do: {:multiboard, Boards.Shared.to_id(id)}
  defp order_key({:board, id}), do: {:board, Boards.Shared.to_id(id)}
  defp order_key("vault-" <> id), do: {:vault, Boards.Shared.to_id(id)}
  defp order_key("multiboard-" <> id), do: {:multiboard, Boards.Shared.to_id(id)}
  defp order_key(board), do: {:board, Boards.Shared.to_id(board)}

  # An order that names none of the user's vaults (or none of their saved
  # multiboards): each placed one goes back behind as many of the things
  # that were named as were in front of it before.
  defp keep_unnamed(user, keys) do
    named = fn kind -> Enum.any?(keys, &match?({^kind, _}, &1)) end

    placed = fn kind ->
      schema = if kind == :vault, do: Vault, else: SavedMultiboard

      from(x in schema,
        where: x.user_id == ^user.id and not is_nil(x.position),
        select: {x.position, x.id}
      )
      |> Repo.all()
      |> Enum.map(fn {pos, id} -> {pos, {kind, id}} end)
    end

    {kept, named_places} =
      Enum.reduce([:vault, :multiboard], {[], []}, fn kind, {kept, named_places} ->
        if named.(kind),
          do: {kept, named_places ++ Enum.map(placed.(kind), &elem(&1, 0))},
          else: {kept ++ placed.(kind), named_places}
      end)

    before = Map.values(board_order(user)) ++ named_places

    kept
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.reduce(keys, fn {{pos, key}, i}, keys ->
      List.insert_at(keys, Enum.count(before, &(&1 < pos)) + i, key)
    end)
  end

  @doc """
  Moves one board — or one of the user's vaults, listed among them — a place
  up or down `among` the boards it is listed with, for `user` alone.
  `direction` is `:up` or `:down`; a board already at the end it is asked to
  move towards stays where it is.
  """
  def nudge_board(%User{} = user, item, direction, among) do
    keys = Enum.map(among, &order_key/1)
    key = order_key(item)
    index = Enum.find_index(keys, &(&1 == key))
    target = if direction == :up, do: index && index - 1, else: index && index + 1

    if (index && target >= 0) and target < length(keys) do
      keys
      |> List.delete_at(index)
      |> List.insert_at(target, key)
      |> then(&reorder_boards(user, &1))
    else
      :ok
    end
  end

  @doc """
  Puts `item` (a board, or a vault listed among them) where `before` is, for
  `user` alone — the move a drag makes. `among` is the boards as they are
  listed now, and `before` the board the dragged one was dropped in front of
  (a board id, or `"vault-<id>"`), or nil for the end of the list.
  """
  def place_board(%User{} = user, item, before, among) do
    key = order_key(item)
    before = order_key(before)
    keys = among |> Enum.map(&order_key/1) |> List.delete(key)
    at = Enum.find_index(keys, &(&1 == before)) || length(keys)
    reorder_boards(user, List.insert_at(keys, at, key))
  end

  @doc """
  The last time anything was logged anywhere in each of `boards`' trees, as a
  map of root board id to `DateTime`. Boards nothing has happened on yet are
  left out.
  """
  def last_activity_at(boards) do
    ids = Enum.map(boards, & &1.id)

    from(a in Activity,
      join: b in Board,
      on: b.id == a.board_id,
      where: b.id in ^ids or b.root_id in ^ids,
      group_by: coalesce(b.root_id, b.id),
      select: {coalesce(b.root_id, b.id), max(a.inserted_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Puts boards in the order `sort` asks for — one of the orders
  `Slipdock.Accounts.User.board_sorts/0` lists.

    * `"manual"` — where the reader put them (see `reorder_boards/2`), with
      boards they have never placed at the end, oldest first
    * `"name"` — by name, case-insensitively
    * `"newest"` / `"oldest"` — when the board was created
    * `"active"` — the most recently touched first (see `last_activity_at/1`)
    * `"cards"` — the busiest first, by how many cards are on the board

  The manual order is the tie-break for every other one, so boards that look
  the same to a sort keep a place that doesn't move about.

  Vaults go in among the boards on the home page, so `boards` may hold
  `%Vault{}`s too: they sort by their own name, age and place, and by the
  activity and cards of the boards they keep inside them. Saved
  multiboards (#1482) go in among them too: by name, age and place, as
  touched when they were last changed, and holding no cards of their own.
  """
  def sort_boards(boards, sort) do
    # The manual order first: every sort below is stable, so boards a sort
    # cannot tell apart fall back on where the reader put them.
    boards = Enum.sort_by(boards, &manual_key/1)

    case sort do
      "name" -> Enum.sort_by(boards, &String.downcase(&1.name || ""))
      "newest" -> Enum.sort_by(boards, &made_key/1, :desc)
      "oldest" -> Enum.sort_by(boards, &made_key/1, :asc)
      "active" -> Enum.sort_by(boards, &touched_at/1, {:desc, DateTime})
      "cards" -> Enum.sort_by(boards, &card_count/1, :desc)
      _manual -> boards
    end
  end

  # Placed boards first, in the order they were placed; the rest behind them,
  # oldest first. The timestamp goes in as a number: `DateTime`s compared as
  # plain terms sort by day before month before year, which is not a date.
  defp manual_key(%{position: nil} = b), do: {1, 0, made_key(b)}
  defp manual_key(%{position: pos} = b), do: {0, pos, made_key(b)}

  defp touched_at(%SavedMultiboard{updated_at: at}), do: at
  defp touched_at(item), do: item.last_activity_at || item.inserted_at

  defp card_count(%Vault{card_count: count}), do: count
  defp card_count(%SavedMultiboard{}), do: 0
  defp card_count(%Board{cards: cards}), do: length(cards)

  # Timestamps are only accurate to the second, so boards made in the same one
  # fall back on the order they were made in rather than on a coin toss — and
  # a board and a vault, whose ids count apart, on the board first.
  defp made_key(%Vault{} = vault), do: {DateTime.to_unix(vault.inserted_at), 1, vault.id}
  defp made_key(%SavedMultiboard{} = m), do: {DateTime.to_unix(m.inserted_at), 2, m.id}
  defp made_key(board), do: {DateTime.to_unix(board.inserted_at), 0, board.id}
end
