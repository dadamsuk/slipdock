defmodule Slipdock.Boards.PubSub do
  @moduledoc """
  The board topics. Every change to a board goes out as
  `{:board_changed, board_id}` on its topic and on the topics of the boards
  above it, and as `{:boards_changed}` to the pages that list boards across
  trees.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Repo

  @pubsub Slipdock.PubSub

  ## PubSub

  def subscribe(board_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(board_id))

  @doc """
  Subscribes the caller to `{:boards_changed}` for the pages that list boards
  across trees (the board index, My work, Favourites) — but only for the
  boards `user` can reach, so a change on somebody else's board wakes nobody
  here.

  A change goes out on its tree's root topic, and a page listens on one per
  root it can reach (`Slipdock.Access.notice_root_ids/1`), plus one of its
  own for reach that grows: a new board, a grant, a group joined. Who hears a
  change is settled by who is subscribed, not worked out when it is sent, so
  a board deleted or a grant revoked still reaches the people who could see
  it — they are subscribed until their next reload, which drops it.

  Returns the root ids subscribed to; hand them back to `resubscribe_all/2`
  after each reload.
  """
  def subscribe_all(%User{} = user) do
    Phoenix.PubSub.subscribe(@pubsub, user_boards_topic(user.id))
    resubscribe_all(user, MapSet.new())
  end

  @doc """
  Brings the root topics `subscribe_all/1` set up into line with what `user`
  can reach now: subscribed to the roots that have come into reach,
  unsubscribed from the ones that went. Returns the new set.
  """
  def resubscribe_all(%User{} = user, subscribed) do
    roots = user |> Slipdock.Access.notice_root_ids() |> MapSet.new()

    subscribed
    |> MapSet.difference(roots)
    |> Enum.each(&Phoenix.PubSub.unsubscribe(@pubsub, root_boards_topic(&1)))

    roots
    |> MapSet.difference(subscribed)
    |> Enum.each(&Phoenix.PubSub.subscribe(@pubsub, root_boards_topic(&1)))

    roots
  end

  @doc "Tells the cross-board pages of everybody who can reach this tree that it changed."
  def notify_boards_changed(root_id),
    do: Phoenix.PubSub.broadcast(@pubsub, root_boards_topic(root_id), {:boards_changed})

  @doc """
  Tells these people's cross-board pages to reload: for a change in what
  they can reach, which no root topic they are on would carry.
  """
  def notify_users_boards_changed(user_ids) do
    user_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Phoenix.PubSub.broadcast(@pubsub, user_boards_topic(&1), {:boards_changed}))
  end

  defp root_boards_topic(root_id), do: "boards:root:#{root_id}"
  defp user_boards_topic(user_id), do: "boards:user:#{user_id}"

  @doc """
  Drops every `{:boards_changed}` already waiting in the caller's mailbox.

  A tree with a lot going on can send a page many of these in the time one
  reload takes. Reloading once per message, the page falls ever further
  behind — and so does anything waiting on it. A handler that drains the rest
  first reloads once for the lot, and is still up to date.
  """
  def drain_boards_changed do
    receive do
      {:boards_changed} -> drain_boards_changed()
    after
      0 -> :ok
    end
  end

  def subscribe_templates, do: Phoenix.PubSub.subscribe(@pubsub, "templates")

  # A change inside a sub-board is also a change to every board above it
  # (the parent card's subcard progress), so notify the whole ancestor chain.
  @doc false
  def broadcast(board_id), do: broadcast_chain(ancestor_board_ids(board_id))

  # The chain runs from the board up to its root, which is last. Taken apart
  # from broadcast/1 so a delete can read the chain before the rows go.
  @doc false
  def broadcast_chain(ids) do
    Enum.each(ids, &Phoenix.PubSub.broadcast(@pubsub, topic(&1), {:board_changed, &1}))
    notify_boards_changed(List.last(ids))
    :ok
  end

  @doc """
  Tells everyone looking at `card`'s board (and the boards above it) that the
  card changed, for a change kept outside the card's own row — a recurring
  card's series (see `Slipdock.Recurrence`).
  """
  def card_changed(%{board_id: board_id}), do: broadcast(board_id)

  # Tags are shared by a whole board tree, so tag changes notify every board in it.
  @doc false
  def broadcast_tree(root_id), do: do_broadcast_tree(root_id)

  defp do_broadcast_tree(root_id) do
    from(b in Board, where: b.id == ^root_id or b.root_id == ^root_id, select: b.id)
    |> Repo.all()
    |> Enum.each(&Phoenix.PubSub.broadcast(@pubsub, topic(&1), {:board_changed, &1}))

    notify_boards_changed(Boards.root_of(root_id))
    :ok
  end

  @doc false
  def broadcast_templates do
    Phoenix.PubSub.broadcast(@pubsub, "templates", {:templates_changed})
    :ok
  end

  @doc """
  A hash of the rows a board page draws its lists from: the board (its name
  and when it last changed), its lists and its cards (where each is, whether
  it is done or archived, when it last changed). A page keeps the one it drew from and asks again now and
  then (`resync` in `SlipdockWeb.BoardLive.Show`, #2918): a different answer
  means it missed a change, whether the broadcast never reached it or its
  connection stopped answering.

  A card's position is in it because a reorder moves positions with
  `update_all`, which leaves `updated_at` alone, and its title because
  `updated_at` is to the second, so an edit in the same second as the last
  change wouldn't move it. A sub-board's rows aren't
  in it: the lists this page draws are its own board's.
  """
  def fingerprint(board_id) when is_integer(board_id) do
    %{rows: [[hash]]} =
      Repo.query!(
        """
        SELECT md5(concat(
          (SELECT concat(name, ':', updated_at) FROM boards WHERE id = $1), '|',
          (SELECT string_agg(concat(id, ':', position, ':', name, ':', updated_at), ',' ORDER BY id)
             FROM columns WHERE board_id = $1), '|',
          (SELECT string_agg(concat(id, ':', column_id, ':', position, ':', completed, ':',
                                    archived_at, ':', updated_at, ':', md5(title)), ',' ORDER BY id)
             FROM cards WHERE board_id = $1)
        ))
        """,
        [board_id]
      )

    hash
  end

  @doc "`board_id` and the ids of the boards above it, the root last."
  def ancestor_board_ids(board_id) do
    case Repo.one(
           from(b in Board,
             left_join: c in Card,
             on: c.id == b.parent_card_id,
             where: b.id == ^board_id,
             select: c.board_id
           )
         ) do
      nil -> [board_id]
      parent_board_id -> [board_id | ancestor_board_ids(parent_board_id)]
    end
  end

  defp topic(board_id), do: "board:#{board_id}"
end
