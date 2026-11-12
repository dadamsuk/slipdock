defmodule Slipdock.Boards.SavedViews do
  @moduledoc """
  Saved views of a board: a person's own filters, and the ones published.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.SavedView
  alias Slipdock.Repo

  ## Saved views

  def get_saved_view!(id), do: Repo.get!(SavedView, id)

  @doc "Finds a saved view on `board` by id or (case-insensitive) name."
  def find_saved_view(%Board{id: board_id}, ref) do
    ref = to_string(ref)

    query =
      case Integer.parse(ref) do
        {id, ""} ->
          from(v in SavedView, where: v.board_id == ^board_id and v.id == ^id)

        _ ->
          name = String.downcase(String.trim(ref))

          from(v in SavedView,
            where: v.board_id == ^board_id and fragment("lower(?)", v.name) == ^name
          )
      end

    case Repo.one(from(q in query, limit: 1)) do
      nil -> {:error, :not_found}
      view -> {:ok, view}
    end
  end

  def list_saved_views(board_id) do
    Repo.all(from(v in SavedView, where: v.board_id == ^board_id, order_by: [asc: v.name]))
  end

  def create_saved_view(%Board{} = board, attrs) do
    %SavedView{board_id: board.id}
    |> SavedView.changeset(Map.put(attrs, "board_id", board.id))
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn v ->
      Boards.ActivityLog.log(Repo, board.id, nil, "view", "saved view “#{v.name}”")
      Boards.PubSub.broadcast(board.id)
    end)
  end

  def update_saved_view(%SavedView{} = view, attrs) do
    view
    |> SavedView.changeset(attrs)
    |> Repo.update()
    |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast(&1.board_id))
  end

  def delete_saved_view(%SavedView{} = view) do
    Repo.delete(view)
    |> Boards.Shared.tap_ok(fn v ->
      Boards.ActivityLog.log(Repo, v.board_id, nil, "view", "deleted view “#{v.name}”")
      Boards.PubSub.broadcast(v.board_id)
    end)
  end

  def change_saved_view(%SavedView{} = view, attrs \\ %{}), do: SavedView.changeset(view, attrs)

  @doc "Gives the view a public token so anyone with the link can read it."
  def publish_saved_view(%SavedView{} = view) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

    view
    |> Ecto.Changeset.change(public_token: token)
    |> Repo.update()
    |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast(&1.board_id))
  end

  @doc "Withdraws the view's public link."
  def unpublish_saved_view(%SavedView{} = view) do
    view
    |> Ecto.Changeset.change(public_token: nil)
    |> Repo.update()
    |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast(&1.board_id))
  end

  @doc "The published view with that token, with its board, or nil."
  def get_published_view(token) when is_binary(token) do
    case Repo.get_by(SavedView, public_token: token) do
      nil -> nil
      view -> %{view | board: Boards.get_board!(view.board_id)}
    end
  end

  def get_published_view(_), do: nil
end
