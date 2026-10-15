defmodule Slipdock.Vaults.Stubs do
  @moduledoc """
  What a sync writes for something shared with you that you filed in your
  own vault (#819): **stubs**, never the content.

  A page, file or folder shared with somebody and also filed in a folder of
  theirs (#818) lives on its owner's board, not in their vault. Their sync
  still shows it where they filed it, as a stub:

    * a page is `Title.md` holding one line, a link to it in Slipdock;
    * a file that is not a note is `name.png.md`, a link to it;
    * a folder is a directory of stubs mirroring what the share reaches,
      subfolders and all.

  A stub is `[Title](https://…/shared/pages/12)` and nothing more, so not a
  word of what was shared lands on the reader's disk. It is worked out on
  every listing from the placements and the share as they stand: renamed or
  moved inside the share, the stub follows; the share taken back or the
  placement taken out, the stub goes. Nothing about the owner's own sync
  changes: their items are at home in their own vault, as ever.

  Each stub is a listing entry `%{kind: "stub", id:, path:, hash:,
  content:}`, sent only to a client that asks for them (`stubs: true`): one
  that knows to write them, put them back when edited, and never send them
  up. `id` is stable for a placement (`"page:12@34"`, `"folder:7@34/page:9"`).
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Vaults.{Layout, Vault}
  alias Slipdock.Wiki.{Archive, Folder, FolderPlacement, Page, Placement, WikiFile}

  @doc """
  The stubs of `vault` for `reader`: `{entries, dirs}`, the stub files and
  the directories they sit in. `base_url` is where the links point.
  """
  @spec build(Vault.t(), Layout.t(), User.t(), String.t()) :: {[map], [String.t()]}
  def build(%Vault{} = vault, layout, %User{} = reader, base_url) do
    vault_boards = MapSet.new(Slipdock.Vaults.board_ids(vault))
    in_vault = Map.keys(layout.folders)
    taken = MapSet.new(Map.keys(layout.paths) ++ Map.keys(layout.file_paths))

    pages =
      from(pl in Placement,
        join: p in Page,
        on: p.id == pl.page_id,
        where: pl.folder_id in ^in_vault and is_nil(p.archived_at),
        order_by: [asc: pl.id],
        select: {pl.folder_id, p}
      )
      |> Repo.all()
      |> Enum.reject(fn {_in, page} -> MapSet.member?(vault_boards, page.board_id) end)
      |> Enum.filter(fn {_in, page} -> readable_page?(reader, page) end)

    folders =
      from(pl in FolderPlacement,
        join: f in Folder,
        on: f.id == pl.folder_id,
        where: pl.in_folder_id in ^in_vault,
        order_by: [asc: pl.id],
        select: {pl.in_folder_id, f}
      )
      |> Repo.all()
      |> Enum.reject(fn {_in, folder} -> MapSet.member?(vault_boards, folder.board_id) end)
      |> Enum.filter(fn {_in, folder} ->
        Access.can_read?(Access.folder_permission(reader, folder))
      end)

    {entries, dirs, taken} =
      Enum.reduce(pages, {[], [], taken}, fn {in_id, page}, acc ->
        dir = layout.folders[in_id]
        add_page(acc, dir, page, "page:#{page.id}@#{in_id}", base_url)
      end)

    {entries, dirs, _taken} =
      Enum.reduce(folders, {entries, dirs, taken}, fn {in_id, folder}, acc ->
        dir = layout.folders[in_id]
        add_folder(acc, dir, folder, "folder:#{folder.id}@#{in_id}", reader, base_url)
      end)

    {Enum.reverse(entries), dirs |> Enum.uniq() |> Enum.sort()}
  end

  @doc "The one line a stub holds: a link to the thing, its name as the text."
  def content(title, url), do: "[#{escape(title)}](#{url})\n"

  defp add_page({entries, dirs, taken}, dir, page, id, base_url) do
    {path, taken} = free_path(join(dir, Archive.safe_name(page.title) <> ".md"), taken)
    url = base_url <> "/shared/pages/#{page.id}"
    {[entry(id, path, content(page.title, url)) | entries], dirs, taken}
  end

  defp add_file({entries, dirs, taken}, dir, file, id, base_url) do
    {path, taken} = free_path(join(dir, Archive.safe_name(file.name) <> ".md"), taken)
    url = base_url <> Wiki.Files.open_path(file)
    {[entry(id, path, content(file.name, url)) | entries], dirs, taken}
  end

  # A folder: its directory, and everything the share reaches inside it.
  defp add_folder({entries, dirs, taken}, dir, folder, id, reader, base_url) do
    {here, taken} = free_path(join(dir, Archive.safe_name(folder.name)), taken)
    acc = {entries, [here | dirs], taken}

    pages =
      from(p in Page,
        where: p.folder_id == ^folder.id and is_nil(p.archived_at),
        order_by: [asc: fragment("lower(?)", p.title), asc: p.id]
      )
      |> Repo.all()
      |> Enum.filter(&readable_page?(reader, &1))

    files =
      from(f in WikiFile,
        where: f.folder_id == ^folder.id and is_nil(f.archived_at),
        order_by: [asc: fragment("lower(?)", f.name), asc: f.id]
      )
      |> Repo.all()

    inner =
      from(f in Folder, where: f.parent_id == ^folder.id, order_by: [asc: f.name, asc: f.id])
      |> Repo.all()

    acc = Enum.reduce(pages, acc, &add_page(&2, here, &1, "#{id}/page:#{&1.id}", base_url))
    acc = Enum.reduce(files, acc, &add_file(&2, here, &1, "#{id}/file:#{&1.id}", base_url))

    Enum.reduce(inner, acc, &add_folder(&2, here, &1, "#{id}/folder:#{&1.id}", reader, base_url))
  end

  defp readable_page?(reader, page), do: Wiki.visible?(page, Access.page_permission(reader, page))

  defp entry(id, path, content) do
    %{
      kind: "stub",
      id: id,
      path: path,
      hash: Slipdock.Vaults.Sync.hash(content),
      content: content
    }
  end

  # A stub never takes a real file's name: a clash gets " (shared)".
  defp free_path(path, taken) do
    key = String.downcase(path)

    if MapSet.member?(taken, key) do
      ext = Path.extname(path)
      free_path(String.trim_trailing(path, ext) <> " (shared)" <> ext, taken)
    else
      {path, MapSet.put(taken, key)}
    end
  end

  defp join(dir, name) when dir in [nil, ""], do: name
  defp join(dir, name), do: dir <> "/" <> name

  defp escape(text), do: String.replace(text, ~r/([\[\]])/, "\\\\\\1")
end
