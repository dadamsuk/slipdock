defmodule Slipdock.Boards.Tags do
  @moduledoc """
  Tags, shared by a whole board tree, and the tags on a card.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Tag
  alias Slipdock.Policy
  alias Slipdock.Repo

  ## Tags

  def list_tags(root_id) do
    Repo.all(from(t in Tag, where: t.board_id == ^root_id, order_by: [asc: t.name]))
  end

  @doc """
  Makes a tag on `board`'s tree. Tags belong to the root of the tree, so
  sub-boards share them, and making one asks write on the root
  (`Slipdock.Policy`, `:create_tag`): `{:error, %Slipdock.Policy.Refused{}}`
  otherwise.
  """
  def create_tag(%Board{} = board, attrs) do
    with :ok <- Policy.authorize(:create_tag, board) do
      root_id = Board.root_id(board)

      %Tag{board_id: root_id}
      |> Tag.changeset(Map.put(attrs, "board_id", root_id))
      |> Repo.insert()
      |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast_tree(&1.board_id))
    end
  end

  @doc """
  Whether a write that carries tags into `board`'s tree (a copy, a move
  across trees, a sub-board from a template) may make the ones the tree
  lacks (#2990). Making a tag changes the root's list, so it asks what the
  tag doors ask, `Slipdock.Access.can_edit_tags?/2`.

  `opts[:make_tags]`, when given, is the door's own answer (REST and MCP
  give it, so a token's narrowing counts too). Else it is the user's: `nil`
  (an automation, a recurring card's next instance, the server's own
  setup) makes them as before.
  """
  def may_make?(%Board{} = board, user, opts \\ []) do
    case Keyword.fetch(opts, :make_tags) do
      {:ok, make?} -> make? == true
      :error -> is_nil(user) or Slipdock.Access.can_edit_tags?(user, board)
    end
  end

  @doc "Renames or recolours a tag: write on the tree's root (`:update_tag`)."
  def update_tag(%Tag{} = tag, attrs) do
    with :ok <- Policy.authorize(:update_tag, tag) do
      tag
      |> Tag.changeset(attrs)
      |> Repo.update()
      |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast_tree(&1.board_id))
    end
  end

  @doc "Deletes a tag from the tree: write on the tree's root (`:delete_tag`)."
  def delete_tag(%Tag{} = tag) do
    with :ok <- Policy.authorize(:delete_tag, tag) do
      Repo.delete(tag) |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast_tree(&1.board_id))
    end
  end

  def get_tag!(id), do: Repo.get!(Tag, id)

  @doc "Puts `tag` on `card`, or takes it off: write on the card (`:toggle_card_tag`)."
  def toggle_card_tag(%Card{} = card, %Tag{} = tag) do
    with :ok <- Policy.authorize(:toggle_card_tag, card), do: toggle(card, tag)
  end

  defp toggle(card, tag) do
    card = Repo.preload(card, :tags)

    tags =
      if Enum.any?(card.tags, &(&1.id == tag.id)),
        do: Enum.reject(card.tags, &(&1.id == tag.id)),
        else: card.tags ++ [tag]

    card
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.update()
    |> Boards.Shared.tap_ok(&Boards.CardEvents.automate_tags_added(&1, card.tags, tags))
    |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast(&1.board_id))
  end
end
