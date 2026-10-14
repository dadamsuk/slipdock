defmodule Slipdock.Vaults.Split do
  @moduledoc """
  Giving a vault folder its own board, in one step (#747).

  Notes maps `/` onto Handbook, and Handbook keeps a `Projects`
  folder; making Project Work the home of `/Projects` means moving what is in that
  folder to Project Work's top (`Slipdock.Wiki.FolderMove`, `contents: true`)
  and mapping `/Projects` onto Project Work (`Slipdock.Vaults.add_mapping/3`), which
  passes the overlap check because the pages have moved first. The notes
  keep their vault paths, so a synced folder sees no change to them; Project
  Work's own pages arrive under `/Projects` as new files.

  Both steps run in one transaction: either the folder has its own board and
  the vault maps onto it, or nothing changed. A preview runs the very same
  steps and rolls them back, so what it reports is what would happen — which
  notes keep their path, which would be renamed (two notes of one title in
  one place), which of the board's pages join, and what the move can't carry.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Boards, Repo, Vaults, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Vaults.{Layout, Mapping, Vault}
  alias Slipdock.Wiki.{Folder, FolderMove}

  @sample 10

  @doc """
  What giving the folder at vault `path` its own board would do. `target`
  is a `%Board{}`, or `{:new, name}` for a board made for it.

      %{path: "/Projects", from: "Handbook", into: "Project Work", new_board: false,
        unchanged: 201, renamed: [%{from:, to:}],
        joining: %{count: 3, sample: ["Projects/Old note.md", ...]},
        move: <FolderMove's report>}
  """
  def preview(%Vault{} = vault, %User{} = user, path, target),
    do: attempt(vault, user, path, target, false)

  @doc "Does it: `{:ok, result}` as `preview/4` describes, plus `board` (the board)."
  def run(%Vault{} = vault, %User{} = user, path, target),
    do: attempt(vault, user, path, target, true)

  defp attempt(vault, user, path, target, commit?) do
    Repo.transaction(fn ->
      with {:ok, mapping, folder, path} <- folder_at(vault, path),
           {:ok, board, new?} <- target_board(target, user),
           :ok <- not_same(board, mapping),
           before = layout(vault),
           {:ok, %{report: report}} <- FolderMove.to_board(folder, board, user, contents: true),
           {:ok, _} <- Vaults.add_mapping(vault, user, %{path: path, board: board}) do
        result =
          vault
          |> layout()
          |> summary(before)
          |> Map.merge(%{
            path: Mapping.display_path(path),
            from: mapping.board.name,
            into: board.name,
            new_board: new?,
            move: report
          })

        if commit?, do: Map.put(result, :board, board), else: Repo.rollback({:preview, result})
      else
        {:error, status, message} -> Repo.rollback({status, message})
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback({:unprocessable_entity, describe(cs)})
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, {:preview, result}} -> {:ok, result}
      {:error, {status, message}} -> {:error, status, message}
    end
  end

  @doc """
  The folder a vault path names, on the board whose mapping holds it:
  `{:ok, mapping, folder, normalized_path}`. A mapping's own path is not a
  folder of a board (it is a board already), nor is a page.
  """
  def folder_at(%Vault{} = vault, path) do
    with {:ok, path} <- Vaults.normalize_path(path),
         {:ok, mapping, rest} <- Vaults.locate(vault, path),
         :ok <- below_mapping(rest, path) do
      ref =
        case mapping.folder do
          nil -> rest
          %Folder{} = top -> Wiki.folder_path(top) <> "/" <> rest
        end

      case find_path(mapping.board, ref) do
        %Folder{} = folder ->
          {:ok, mapping, folder, path}

        nil ->
          {:error, :not_found,
           "no folder at #{Mapping.display_path(path)} on #{mapping.board.name}"}
      end
    end
  end

  defp below_mapping("", path),
    do:
      {:error, :unprocessable_entity,
       "#{Mapping.display_path(path)} is a mapping already: it has a board of its own"}

  defp below_mapping(_rest, _path), do: :ok

  # A folder by its path from the board's top, segment by segment, names
  # compared case aside as a synced folder's would be.
  defp find_path(board, ref) do
    folders = Wiki.folders(board)

    ref
    |> String.split("/", trim: true)
    |> Enum.reduce_while(nil, fn name, parent ->
      parent_id = parent && parent.id

      case Enum.find(folders, &(&1.parent_id == parent_id and same?(&1.name, name))) do
        nil -> {:halt, nil}
        folder -> {:cont, folder}
      end
    end)
  end

  defp same?(a, b), do: String.downcase(a) == String.downcase(b)

  @doc """
  A folder's vault path in `vault`, as the vault's tree shows it, or nil
  when no mapping of the vault holds it. The deepest mapping above it wins.
  """
  def vault_path(%Vault{} = vault, %Folder{} = folder) do
    vault = Repo.preload(vault, [mappings: [:board, :folder]], force: true)
    chain = Wiki.Folders.ancestors(folder) ++ [folder]
    ids = Enum.map(chain, & &1.id)

    vault.mappings
    |> Enum.filter(&(&1.board_id == folder.board_id))
    |> Enum.map(fn m ->
      depth = if m.folder_id, do: Enum.find_index(ids, &(&1 == m.folder_id)), else: -1
      {depth, m}
    end)
    |> Enum.reject(fn {depth, _m} -> is_nil(depth) end)
    |> Enum.max_by(fn {depth, _m} -> depth end, fn -> nil end)
    |> case do
      nil ->
        nil

      {depth, m} ->
        below = chain |> Enum.drop(depth + 1) |> Enum.map(& &1.name)
        ([m.path] ++ below) |> Enum.reject(&(&1 == "")) |> Enum.join("/")
    end
  end

  defp target_board(%Board{} = board, _user), do: {:ok, board, false}

  defp target_board({:new, name}, %User{} = user) do
    case String.trim(to_string(name)) do
      "" ->
        {:error, :unprocessable_entity, "say what the new board is called"}

      name ->
        with {:ok, board} <- Boards.create_board(%{"name" => name}, owner_id: user.id),
             do: {:ok, Boards.get_board!(board.id), true}
    end
  end

  defp target_board(_, _user), do: {:error, :unprocessable_entity, "say which board"}

  defp not_same(%Board{id: id}, %Mapping{board_id: id}),
    do: {:error, :unprocessable_entity, "the folder is on that board already"}

  defp not_same(_board, _mapping), do: :ok

  defp layout(vault),
    do: vault |> Layout.build() |> Map.fetch!(:pages) |> Map.new(fn {id, p} -> {id, p.path} end)

  # What a synced folder would see: notes at the same path (no change),
  # notes whose file name moves, and files that arrive.
  defp summary(later, before) do
    kept = for {id, path} <- later, Map.get(before, id) == path, do: id

    renamed =
      for {id, path} <- later,
          was = Map.get(before, id),
          was not in [nil, path],
          do: %{from: was, to: path}

    joining = for {id, path} <- later, not Map.has_key?(before, id), do: path

    %{
      unchanged: length(kept),
      renamed: Enum.sort_by(renamed, & &1.to),
      joining: %{
        count: length(joining),
        sample: joining |> Enum.sort() |> Enum.take(@sample)
      }
    }
  end

  defp describe(cs) do
    cs.errors |> Enum.map_join(", ", fn {field, {message, _}} -> "#{field} #{message}" end)
  end
end
