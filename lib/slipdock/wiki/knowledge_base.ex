defmodule Slipdock.Wiki.KnowledgeBase do
  @moduledoc """
  Each person's Knowledge Base (W-2201): the part of their wiki that belongs
  to no board of work. Underneath it is a board of kind `"wiki"`, so its
  pages are pages like any other, with codes, history, links and sync, but
  it is nobody's board to work on: no list of boards shows it, it counts
  against no limit, and its board view opens its wiki. It is always first
  at the top of the wiki's tree.

  Everybody has one: `ensure/1` makes it the first time it is wanted.
  `adopt/2` makes an existing board of theirs the Knowledge Base instead, as
  a wiki brought in from elsewhere wants.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Repo

  @name "Knowledge Base"

  @doc "The name a new Knowledge Base is given."
  def name, do: @name

  @doc "`user`'s Knowledge Base, or nil before it is made."
  def get(%User{id: user_id}) do
    from(b in Board,
      where: b.owner_id == ^user_id and b.kind == "wiki" and is_nil(b.parent_card_id),
      order_by: [asc: b.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "`user`'s Knowledge Base, made now if they have none: `{:ok, board}`."
  def ensure(%User{} = user) do
    case get(user) do
      %Board{} = board -> {:ok, board}
      nil -> Boards.create_board(%{"name" => @name}, owner_id: user.id, wiki: true)
    end
  end

  @doc """
  Makes `board`, a root board `user` owns, their Knowledge Base, named
  #{inspect(@name)} unless `name:` says otherwise. Refused when they have one
  already, or the board is a sub-board or not theirs. `{:ok, board}`.
  """
  def adopt(%User{} = user, %Board{} = board, opts \\ []) do
    cond do
      board.owner_id != user.id ->
        {:error, "the board isn't yours"}

      not is_nil(board.parent_card_id) ->
        {:error, "a sub-board can't be the Knowledge Base"}

      Board.wiki?(board) ->
        {:ok, board}

      get(user) ->
        {:error, "you have a Knowledge Base already"}

      true ->
        name = opts[:name] || @name

        with {:ok, adopted} <-
               board
               |> Ecto.Changeset.change(kind: "wiki", name: name, archived_at: nil)
               |> Repo.update() do
          # Its folder is renamed: a synced client moves what it holds.
          if adopted.name != board.name,
            do: Slipdock.Wiki.Changes.record(adopted.id, "board", adopted.id)

          {:ok, adopted}
        end
    end
  end
end
