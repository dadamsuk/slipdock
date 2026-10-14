defmodule Slipdock.Wiki.Placements do
  @moduledoc """
  Filing a page in several folders (W-103 R12).

  A page has exactly one **home** folder — `folder_id`, as it always had —
  and any number of folders it is **also filed in**. They are placements,
  like symbolic links: every one opens the same page, with one body and one
  history. On disk (when the vault is synced) the page is written once, at
  its home.

  The rules:

    * A placement is in a folder on the page's own board, or — when that
      board is in a vault — on any board of the same vault.
    * Placing needs write on the page's board and on the folder's: it
      changes what that folder holds.
    * The home folder is not a placement; filing a page home where it was
      also filed drops the placement, so a listing shows it once.
    * Archiving or moving the page keeps its placements. Taking a placement
      away never archives the page. Deleting a folder takes its placements
      (by cascade), as deleting the page does.
    * Whoever cannot open the page does not see it in any folder.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Vaults, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Wiki.{Folder, Page, Placement}

  @doc "The folders a page is also filed in, with their boards, in the order they were added."
  def folders(%Page{id: id}) do
    from(pl in Placement,
      join: f in assoc(pl, :folder),
      where: pl.page_id == ^id,
      order_by: [asc: pl.inserted_at, asc: pl.id],
      select: f
    )
    |> Repo.all()
    |> Repo.preload(:board)
  end

  @doc """
  Files `page` in `folder` as well as its home. `user` needs write on both
  boards. Filing it twice in one folder is filing it once.
  """
  def add(%Page{} = page, %Folder{} = folder, %User{} = user) do
    cond do
      folder.id == page.folder_id ->
        {:error, :unprocessable_entity, "that is the page's home folder already"}

      not reachable?(page, folder) ->
        {:error, :unprocessable_entity,
         "a page can only be filed in folders on its own board, or on boards in the same vault"}

      not writer?(user, page.board_id) or not writer?(user, folder.board_id) ->
        {:error, :forbidden, "you need to be able to edit both the page's board and the folder's"}

      true ->
        position =
          Repo.one(
            from(pl in Placement, where: pl.folder_id == ^folder.id, select: max(pl.position))
          )

        %Placement{}
        |> Placement.changeset(%{
          page_id: page.id,
          folder_id: folder.id,
          position: (position || -1) + 1
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:page_id, :folder_id])
        |> case do
          {:ok, _} ->
            touched(page, folder)
            {:ok, folders(page)}

          error ->
            error
        end
    end
  end

  @doc "Takes `page` out of a folder it was also filed in. The page itself is untouched."
  def remove(%Page{} = page, %Folder{} = folder, %User{} = user) do
    cond do
      not writer?(user, page.board_id) ->
        {:error, :forbidden, "you don't edit this page"}

      true ->
        case Repo.delete_all(
               from(pl in Placement, where: pl.page_id == ^page.id and pl.folder_id == ^folder.id)
             ) do
          {0, _} ->
            {:error, :not_found, "a placement of #{page.code} in #{Wiki.folder_path(folder)}"}

          _ ->
            touched(page, folder)
            {:ok, folders(page)}
        end
    end
  end

  @doc """
  The folder a vault path names, for a page on a board in a vault:
  `"/Projects/Notes"` is the folder `Notes` under whatever `/Projects` is mapped to.
  With `create: true` the folders along it are made, as filing makes them.
  """
  def folder_at(%Page{} = page, "/" <> _ = path, opts \\ []) do
    with %Vaults.Vault{} = vault <-
           Vaults.for_board(page.board_id) ||
             {:error, :unprocessable_entity,
              "#{page.code} is not on a board in a vault, so it has no vault paths"},
         {:ok, mapping, rest} <- Vaults.locate(vault, path) do
      mapping = Repo.preload(mapping, [:board, :folder])
      base = if mapping.folder, do: Wiki.folder_path(mapping.folder), else: nil
      full = [base, rest] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("/")

      cond do
        full == "" ->
          {:error, :unprocessable_entity, "#{path} is a board's wiki, not a folder in it"}

        opts[:create] ->
          Wiki.create_folder(mapping.board, %{"name" => full})

        true ->
          Wiki.find_folder(mapping.board, full)
      end
    end
  end

  @doc "Drops the placement in a folder that has just become the page's home."
  def drop_home(%Page{folder_id: nil}), do: :ok

  def drop_home(%Page{id: id, folder_id: folder_id}) do
    Repo.delete_all(
      from(pl in Placement, where: pl.page_id == ^id and pl.folder_id == ^folder_id)
    )

    :ok
  end

  @doc """
  The pages also filed in `folder`, marked `also: true`, that `reader` may
  open (with no reader, only those on the folder's own board). Archived pages only with `archived: true`
  or `:all`, as a listing asks.
  """
  def pages_in(%Folder{id: folder_id, board_id: board_id}, reader \\ nil, opts \\ []) do
    from(p in Page,
      join: pl in Placement,
      on: pl.page_id == p.id,
      where: pl.folder_id == ^folder_id,
      order_by: [asc: pl.position, asc: p.title],
      preload: ^Wiki.board_preloads()
    )
    |> archived(Keyword.get(opts, :archived, false))
    |> Repo.all()
    |> Enum.filter(&readable?(&1, reader, board_id))
    |> Enum.map(&%{&1 | also: true})
  end

  defp archived(query, :all), do: query
  defp archived(query, true), do: where(query, [p], not is_nil(p.archived_at))
  defp archived(query, _), do: where(query, [p], is_nil(p.archived_at))

  @doc "`pages_in/3` for every folder of a board at once: folder id → pages."
  def pages_by_folder(board_id, reader \\ nil, opts \\ []) do
    folder_ids = from(f in Folder, where: f.board_id == ^board_id, select: f.id)

    from(p in Page,
      join: pl in Placement,
      on: pl.page_id == p.id,
      where: pl.folder_id in subquery(folder_ids),
      order_by: [asc: pl.position, asc: p.title],
      select: {pl.folder_id, p},
      preload: ^Wiki.board_preloads()
    )
    |> archived(Keyword.get(opts, :archived, false))
    |> Repo.all()
    |> Enum.filter(fn {_folder_id, page} -> readable?(page, reader, board_id) end)
    |> Enum.group_by(&elem(&1, 0), fn {_folder_id, page} -> %{page | also: true} end)
  end

  # With nobody named, only what the folder's own board holds — a caller
  # that has not said who is reading must not be handed another board's page.
  defp readable?(page, nil, board_id), do: page.board_id == board_id

  defp readable?(page, reader, _board_id),
    do: Wiki.visible?(page, Access.page_permission(reader, page))

  defp writer?(user, board_id) do
    case Repo.get(Slipdock.Boards.Board, board_id) do
      nil -> false
      board -> Access.can_write?(Access.board_permission(user, board))
    end
  end

  defp reachable?(%Page{board_id: id}, %Folder{board_id: id}), do: true

  defp reachable?(%Page{board_id: page_board}, %Folder{board_id: folder_board}) do
    case Vaults.for_board(page_board) do
      nil -> false
      vault -> folder_board in Vaults.board_ids(vault)
    end
  end

  defp touched(page, folder) do
    Slipdock.Wiki.Changes.record(page.board_id, "page", page.id)
    Wiki.broadcast_board(page.board_id)
    if folder.board_id != page.board_id, do: Wiki.broadcast_board(folder.board_id)
  end
end
