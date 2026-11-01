defmodule Slipdock.Vaults.Names do
  @moduledoc """
  What a vault's directories are called and whether they are put away
  (W-2201 §Names), for whatever lists them: the sync listing, the change feed
  and the web tree. `Slipdock.Vaults.Layout` says where things are; this says
  the rest, read in one go so a caller asks per entry without a query.

  A directory's `title` is the full name, its `short_name` the card's when it
  has one. `archived` says a board or a card put it away. It holds for
  everything below too, since a page or a sub-board under an archived card
  stays where it is: archived is a flag, never part of a path.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Vaults.Layout
  alias Slipdock.Wiki.{CardFolders, Folder}

  @type t :: %{
          boards: %{pos_integer => map},
          folders: %{pos_integer => map},
          virtual: %{String.t() => map},
          by_dir: %{String.t() => map},
          archived_dirs: MapSet.t(String.t())
        }

  @doc "The names of everything `Layout.build/1` placed."
  @spec build(Layout.t()) :: t
  def build(%{boards: boards, folders: folders, virtual: virtual}) do
    board_ids = Map.keys(boards)
    folder_ids = Map.keys(folders)

    board_names =
      from(b in Board,
        where: b.id in ^board_ids,
        select:
          {b.id, %{title: b.name, short_name: nil, card_id: nil, archived_at: b.archived_at}}
      )
      |> Repo.all()
      |> Map.new()

    folder_names =
      from(f in Folder,
        left_join: c in Card,
        on: c.id == f.card_id,
        where: f.id in ^folder_ids,
        select:
          {f.id,
           %{
             title: coalesce(c.title, f.name),
             short_name: c.short_name,
             card_id: f.card_id,
             archived_at: c.archived_at
           }}
      )
      |> Repo.all()
      |> Map.new()

    virtual_names =
      Map.new(virtual, fn {dir, %{card: card, board_id: board_id}} ->
        {dir,
         %{
           board_id: board_id,
           title: if(card, do: card.title, else: CardFolders.root_name()),
           short_name: card && card.short_name,
           card_id: card && card.id,
           archived_at: card && card.archived_at
         }}
      end)

    archived_dirs =
      [
        dirs_of(board_names, boards),
        dirs_of(folder_names, folders),
        for({dir, %{archived_at: %{}}} <- virtual_names, do: dir)
      ]
      |> Enum.concat()
      |> MapSet.new()

    by_dir =
      virtual_names
      |> Map.merge(keyed(board_names, boards))
      |> Map.merge(keyed(folder_names, folders))

    %{
      boards: shown(board_names, archived_dirs, boards),
      folders: shown(folder_names, archived_dirs, folders),
      virtual:
        Map.new(virtual_names, fn {dir, name} -> {dir, show(name, dir, archived_dirs)} end),
      by_dir: by_dir,
      archived_dirs: archived_dirs
    }
  end

  defp dirs_of(names, dirs) do
    for {id, %{archived_at: %{}}} <- names, dir = dirs[id], do: dir
  end

  defp keyed(names, dirs) do
    for {id, name} <- names, dir = dirs[id], into: %{}, do: {dir, name}
  end

  defp shown(names, archived_dirs, dirs) do
    Map.new(names, fn {id, name} -> {id, show(name, dirs[id], archived_dirs)} end)
  end

  defp show(name, dir, archived_dirs) do
    name
    |> Map.delete(:archived_at)
    |> Map.put(:archived, archived_under?(archived_dirs, dir))
  end

  @doc "Whether a board or a card put away the directory `dir`, or one above it."
  def archived?(%{archived_dirs: archived_dirs}, dir), do: archived_under?(archived_dirs, dir)

  defp archived_under?(_archived_dirs, nil), do: false

  defp archived_under?(archived_dirs, dir) do
    segments = String.split(dir, "/", trim: true)

    Enum.any?(1..length(segments)//1, fn n ->
      MapSet.member?(archived_dirs, segments |> Enum.take(n) |> Enum.join("/"))
    end)
  end

  @doc """
  The name to show for the directory at `path`, by the reader's choice
  (`users.tree_names`): `{shown, full}`. Nil for a directory with no name of
  its own, such as a page with pages under it.
  """
  def label(%{by_dir: by_dir}, path, choice) do
    case by_dir[path] do
      nil -> nil
      %{title: title} = name -> {pick(name, choice), title}
    end
  end

  @doc """
  What to call something, by the reader's choice: its short name when they
  chose those and it has one, otherwise its title. Whole either way: a place
  too narrow for it shortens it with CSS.
  """
  def pick(%{short_name: short}, "short") when is_binary(short) and short != "", do: short
  def pick(%{title: title}, _choice), do: title
end
