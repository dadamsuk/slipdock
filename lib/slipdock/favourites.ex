defmodule Slipdock.Favourites do
  @moduledoc """
  Favourites: the handful of places one person keeps going back to.

  A board has more in it than anyone works on at once. The board you live in
  is one of nine; the list you actually move cards through is one of six on
  it; the card you are reporting against every day is one of hundreds. On a
  phone that is three or four taps every time, and the last one is a hunt.

  Marking something a favourite puts it on `/favourites`, which is a tab of
  the phone's floating navigation — so anything you go back to often is a
  few taps from anywhere: the button, the tab, then the thing.

  Favourites belong to the person, not the board. Two people on the same
  board keep different ones, and sharing a board never hands anyone else's
  shortcuts over. What a person may favourite is what they may read, and
  `list/1` re-checks that on the way out: access can be revoked long after
  the row was written.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Column, SavedView}
  alias Slipdock.Favourites.Favourite
  alias Slipdock.Wiki.Page
  alias Slipdock.{Access, Repo, Wiki}

  @kinds Favourite.kinds()

  ## Reading -------------------------------------------------------------------

  @doc """
  Everything `user` has favourited and can still read, newest last.

  Each entry is a map of `:kind`, `:id` (the favourite's own id), `:resource`
  and `:board` — enough for a caller to name it and link to it without going
  back to the database.
  """
  def list(%User{} = user) do
    from(f in Favourite, where: f.user_id == ^user.id, order_by: [asc: f.inserted_at, asc: f.id])
    |> Repo.all()
    |> Repo.preload([
      :board,
      [column: :board],
      [card: [:board, :column]],
      [saved_view: :board],
      [page: :board]
    ])
    |> Enum.map(&entry/1)
    |> Enum.filter(&readable?(user, &1))
  end

  def list(_), do: []

  @doc """
  What `user` has favourited, as a set of `{kind, id}` pairs.

  This is what a page checks to draw its stars, so it is one small query and
  no preloads: the things themselves are already on the page.
  """
  def marks(%User{} = user) do
    from(f in Favourite,
      where: f.user_id == ^user.id,
      select: {f.board_id, f.column_id, f.card_id, f.saved_view_id, f.page_id}
    )
    |> Repo.all()
    |> Enum.map(fn
      {id, nil, nil, nil, nil} -> {:board, id}
      {nil, id, nil, nil, nil} -> {:column, id}
      {nil, nil, id, nil, nil} -> {:card, id}
      {nil, nil, nil, id, nil} -> {:view, id}
      {nil, nil, nil, nil, id} -> {:page, id}
    end)
    |> MapSet.new()
  end

  def marks(_), do: MapSet.new()

  @doc """
  Reads a kind's name off the wire: `{:ok, kind}`, or `:error` for anything
  that is not one of `Slipdock.Favourites.Favourite.kinds/0`.
  """
  def kind(name) when is_binary(name) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == name)) do
      nil -> :error
      kind -> {:ok, kind}
    end
  end

  def kind(kind) when kind in @kinds, do: {:ok, kind}
  def kind(_), do: :error

  @doc "Whether `{kind, id}` is in a set from `marks/1`."
  def favourite?(marks, kind, id) when kind in @kinds, do: MapSet.member?(marks, {kind, id})

  @doc "How many favourites `user` has, without loading them."
  def count(%User{} = user),
    do: Repo.aggregate(from(f in Favourite, where: f.user_id == ^user.id), :count)

  def count(_), do: 0

  ## Writing -------------------------------------------------------------------

  @doc """
  Adds or removes a favourite, whichever the user does not already have.

  Returns `{:ok, :added}` or `{:ok, :removed}`, or `{:error, :not_found}`
  when the thing is gone or was never theirs to see.
  """
  def toggle(%User{} = user, kind, id) when kind in @kinds do
    with {:ok, resource} <- fetch(kind, id),
         true <- readable_resource?(user, kind, resource) do
      case one(user, kind, id) do
        nil ->
          {:ok, _} =
            %Favourite{}
            |> Favourite.changeset(%{Favourite.field(kind) => id, user_id: user.id})
            |> Repo.insert()

          {:ok, :added}

        favourite ->
          Repo.delete(favourite)
          {:ok, :removed}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Marks `{kind, id}` a favourite of `user`'s; a no-op if it already is."
  def add(%User{} = user, kind, id) when kind in @kinds do
    if one(user, kind, id), do: {:ok, :unchanged}, else: toggle(user, kind, id)
  end

  @doc "Takes `{kind, id}` off `user`'s favourites; a no-op if it was not one."
  def remove(%User{} = user, kind, id) when kind in @kinds do
    case one(user, kind, id) do
      nil -> {:ok, :unchanged}
      favourite -> Repo.delete(favourite) && {:ok, :removed}
    end
  end

  ## Internals -----------------------------------------------------------------

  defp one(%User{} = user, kind, id) do
    field = Favourite.field(kind)
    Repo.get_by(Favourite, [user_id: user.id] ++ [{field, id}])
  end

  defp fetch(:board, id), do: get(Board, id)
  defp fetch(:column, id), do: get(Column, id)
  defp fetch(:card, id), do: get(Card, id)
  defp fetch(:view, id), do: get(SavedView, id)
  defp fetch(:page, id), do: get(Page, id)

  defp get(schema, id) do
    case Repo.get(schema, id) do
      nil -> {:error, :not_found}
      resource -> {:ok, resource}
    end
  end

  defp entry(%Favourite{} = f) do
    kind = Favourite.kind(f)
    resource = resource(f, kind)

    %{
      id: f.id,
      kind: kind,
      resource: resource,
      resource_id: Favourite.resource_id(f),
      board: board_of(kind, resource)
    }
  end

  defp resource(f, :board), do: f.board
  defp resource(f, :column), do: f.column
  defp resource(f, :card), do: f.card
  defp resource(f, :view), do: f.saved_view
  defp resource(f, :page), do: f.page

  defp board_of(:board, board), do: board
  defp board_of(_kind, nil), do: nil
  defp board_of(_kind, resource), do: resource.board

  # A row survives only while its thing is still there, still readable, and
  # still somewhere worth going: an archived card is none of those.
  defp readable?(_user, %{resource: nil}), do: false

  defp readable?(_user, %{kind: :card, resource: %Card{archived_at: at}}) when not is_nil(at),
    do: false

  defp readable?(_user, %{kind: :page, resource: %Page{archived_at: at}}) when not is_nil(at),
    do: false

  defp readable?(user, %{kind: kind, resource: resource}),
    do: readable_resource?(user, kind, resource)

  defp readable_resource?(user, :board, board),
    do: Access.board_permission(user, board) != :none

  defp readable_resource?(user, :column, column),
    do: Access.can_read?(Access.board_permission(user, Repo.get!(Board, column.board_id)))

  defp readable_resource?(user, :card, card),
    do: Access.can_read?(Access.card_permission(user, card))

  defp readable_resource?(user, :view, view),
    do: Access.view_permission(user, view) != :none

  # A draft is not somewhere to go back to unless you could have written it.
  defp readable_resource?(user, :page, page),
    do: Wiki.visible?(page, Access.page_permission(user, page))
end
