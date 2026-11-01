defmodule Slipdock.Wiki.CardFolders do
  @moduledoc """
  A card's own folder (W-2201 rule 3): `<Board>/Cards/<card>`, a real wiki
  folder tied to the card by id, so a rename can't lose it.

  Made the first time the card gets a page of its own, under a board-level
  `Cards` folder made the same way. Its stored name is the card's title, for
  display. On disk it is `short_name || title`, read through `sources/1`, so a
  long title never makes a long path. Archiving the card leaves it where it is.

  Attaching an existing page to a card is a pin, and moves nothing.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Folder, Folders}

  @root "Cards"

  @doc "The name of the board-level folder card folders sit in."
  def root_name, do: @root

  @doc "The card's folder, made along with `Cards` if need be: `{:ok, folder}`."
  def ensure(%Card{} = card) do
    case find(card) do
      %Folder{} = folder -> {:ok, folder}
      nil -> create(card)
    end
  end

  @doc "The card's folder on the card's own board, or nil."
  def find(%Card{id: id, board_id: board_id}) do
    case Repo.one(from(f in Folder, where: f.card_id == ^id)) do
      %Folder{board_id: ^board_id} = folder ->
        folder

      # The card has moved board. What was filed stays where it was, an
      # ordinary folder now; a new one is made on the card's board if wanted.
      %Folder{} = left ->
        left |> Ecto.Changeset.change(card_id: nil) |> Repo.update!()
        nil

      nil ->
        nil
    end
  end

  defp create(%Card{} = card) do
    board = Repo.get!(Board, card.board_id)

    with {:ok, root} <- root(board),
         {:ok, folder} <-
           Folders.create_literal(board, %{
             "name" => display_name(card),
             "slug" => "card-#{card.id}",
             "parent_id" => root.id
           }) do
      folder |> Ecto.Changeset.change(card_id: card.id) |> Repo.update()
    end
  end

  defp root(%Board{id: board_id} = board) do
    from(f in Folder,
      where: f.board_id == ^board_id and is_nil(f.parent_id),
      where: fragment("lower(?) = lower(?)", f.name, ^@root),
      order_by: [asc: f.id],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> Wiki.create_folder(board, %{"name" => @root})
      folder -> {:ok, folder}
    end
  end

  @doc "Keeps the folder's stored name on the card's title, when it has a folder."
  def renamed(%Card{} = card) do
    from(f in Folder, where: f.card_id == ^card.id)
    |> Repo.update_all(set: [name: display_name(card)])

    :ok
  end

  defp display_name(%Card{title: title}),
    do: title |> String.trim() |> String.slice(0, Folder.name_length())

  @doc """
  What each card folder of `board_ids` is called on disk, for
  `Slipdock.Wiki.DiskName.assign/2`: `%{folder_id => {name, fallback}}`.
  """
  def sources(board_ids) do
    from(f in Folder,
      join: c in Card,
      on: c.id == f.card_id,
      where: f.board_id in ^board_ids,
      select: {f.id, c.id, c.short_name, c.title}
    )
    |> Repo.all()
    |> Map.new(fn {folder_id, card_id, short_name, title} ->
      {folder_id, {short_name || title, "Card #{card_id}"}}
    end)
  end
end
