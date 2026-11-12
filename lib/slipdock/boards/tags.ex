defmodule Slipdock.Boards.Tags do
  @moduledoc """
  Tags, shared by a whole board tree, and the tags on a card.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Tag
  alias Slipdock.Repo

  ## Tags

  def list_tags(root_id) do
    Repo.all(from(t in Tag, where: t.board_id == ^root_id, order_by: [asc: t.name]))
  end

  # Tags belong to the root of the board tree so sub-boards share them.
  def create_tag(%Board{} = board, attrs) do
    root_id = Board.root_id(board)

    %Tag{board_id: root_id}
    |> Tag.changeset(Map.put(attrs, "board_id", root_id))
    |> Repo.insert()
    |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast_tree(&1.board_id))
  end

  def update_tag(%Tag{} = tag, attrs) do
    tag
    |> Tag.changeset(attrs)
    |> Repo.update()
    |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast_tree(&1.board_id))
  end

  def delete_tag(%Tag{} = tag) do
    Repo.delete(tag) |> Boards.Shared.tap_ok(&Boards.PubSub.broadcast_tree(&1.board_id))
  end

  def get_tag!(id), do: Repo.get!(Tag, id)

  def toggle_card_tag(%Card{} = card, %Tag{} = tag) do
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
