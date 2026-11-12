defmodule Slipdock.Boards.StatusUpdates do
  @moduledoc """
  Status updates on a card or a wiki page, and the health they state.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.StatusUpdate
  alias Slipdock.Repo

  ## Status updates

  @doc """
  Records what `user` believes about the health of a card or a wiki page,
  with an optional note. A spec can be off track as surely as the work can.

  `quiet: true` is for the server's own step statuses (#2022,
  `Slipdock.StepStatus`): the update is kept and open views refresh, but it
  writes no activity line and isn't indexed, so nobody following the card
  hears of a routine step. A person's update is never quiet.
  """
  def add_status_update(owner, user, attrs, opts \\ []) do
    quiet? = Keyword.get(opts, :quiet, false)

    %StatusUpdate{user_id: user && user.id}
    |> struct!(Boards.Shared.owned_by(owner))
    |> StatusUpdate.changeset(attrs)
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn u ->
      Slipdock.Wiki.Links.reconcile_status(u)
      Boards.PubSub.broadcast_tree(Boards.root_of(owner.board_id))
      if quiet?, do: Boards.PubSub.broadcast(owner.board_id), else: status_reported(owner, u)
    end)
  end

  defp status_reported(owner, u) do
    note = if u.body, do: ": #{String.slice(u.body, 0, 120)}", else: ""

    Boards.Shared.log_owned(
      owner,
      "status",
      "reported “#{owner.title}” #{String.downcase(StatusUpdate.health_label(u.health))}#{note}"
    )

    Boards.Shared.notify_owned(owner)
  end

  def delete_status_update(id) do
    update = Repo.get!(StatusUpdate, id)
    owner = Boards.Shared.owner_of(update)

    Repo.delete(update)
    |> Boards.Shared.tap_ok(fn _ ->
      Boards.PubSub.broadcast_tree(Boards.root_of(owner.board_id))
      Boards.Shared.notify_owned(owner)
    end)
  end

  @doc "The latest stated health per card id, for the given cards."
  def latest_stated_health(card_ids) when is_list(card_ids) do
    from(u in StatusUpdate,
      where: u.card_id in ^card_ids,
      order_by: [desc: u.inserted_at, desc: u.id],
      select: {u.card_id, u.health}
    )
    |> Repo.all()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Map.new()
  end

  @doc "The latest stated health per page id, for the given pages."
  def latest_stated_health_for_pages(page_ids) when is_list(page_ids) do
    from(u in StatusUpdate,
      where: u.page_id in ^page_ids,
      order_by: [desc: u.inserted_at, desc: u.id],
      select: {u.page_id, u.health}
    )
    |> Repo.all()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Map.new()
  end
end
