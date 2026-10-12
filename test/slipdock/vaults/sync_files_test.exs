defmodule Slipdock.Vaults.SyncFilesTest do
  @moduledoc """
  Files in a vault that are not notes (W-103 R2.9): images, PDFs and
  drawings stored as wiki files at the same vault path, synced by hash,
  counted against storage, and drawn by `![[image.png]]`.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query

  import Slipdock.Fixtures

  alias Slipdock.{Quota, Vaults, Wiki}
  alias Slipdock.Vaults.{Layout, Sync}
  alias Slipdock.Wiki.{Changes, Files, WikiFile}
  alias SlipdockWeb.Wiki.Renderer

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kb"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobs"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})
    %{user: user, kb: kb, jobs: jobs, vault: vault}
  end

  defp source(bytes) do
    path = Path.join(System.tmp_dir!(), "wiki-file-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp put!(vault, user, path, bytes, extra \\ %{}) do
    {:ok, entry} =
      Sync.write_file(vault, user, Map.merge(%{"path" => path}, extra), source(bytes))

    entry
  end

  test "a new file is stored at its vault path, its folders made, and listed by hash",
       %{vault: vault, user: user, kb: kb} do
    entry = put!(vault, user, "Images/Diagram.png", "png bytes")

    file = Repo.get!(WikiFile, entry.id)
    assert file.board_id == kb.id
    assert Wiki.folder_path(Wiki.Folders.get!(file.folder_id)) == "Images"
    assert file.sha256 == sha("png bytes")
    assert file.content_type == "image/png"
    assert File.read!(Files.disk_path(file)) == "png bytes"
    assert entry.path == "Images/Diagram.png"

    assert [%{kind: "file", path: "Images/Diagram.png", hash: hash, size: 9}] =
             Sync.listing(vault, user).entries

    assert hash == sha("png bytes")
    assert {:ok, %WikiFile{}, %{hash: ^hash}} = Sync.read_file(vault, user, file.id)
  end

  test "new bytes against the right base replace the old, whose bytes go; a stale base conflicts",
       %{vault: vault, user: user} do
    entry = put!(vault, user, "a.pdf", "one")
    old_path = Files.disk_path(Repo.get!(WikiFile, entry.id))

    replaced = put!(vault, user, "a.pdf", "two", %{"id" => entry.id, "base" => entry.hash})
    assert replaced.id == entry.id
    assert replaced.hash == sha("two")
    refute File.exists?(old_path)

    assert {:error, :conflict, current} =
             Sync.write_file(
               vault,
               user,
               %{"path" => "a.pdf", "id" => entry.id, "base" => entry.hash},
               source("three")
             )

    assert current.hash == sha("two")
  end

  test "a path another file has is a conflict, and a page's directory or a note is refused",
       %{vault: vault, user: user, kb: kb} do
    put!(vault, user, "a.pdf", "one")

    assert {:error, :conflict, %{path: "a.pdf"}} =
             Sync.write_file(vault, user, %{"path" => "A.pdf"}, source("x"))

    {:ok, parent} = Wiki.create_page(kb, %{"title" => "Deploys"})
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Rollback", "parent_id" => parent.id})

    assert {:error, :unprocessable_entity, msg} =
             Sync.write_file(vault, user, %{"path" => "Deploys/x.png"}, source("x"))

    assert msg =~ "page's own folder"

    assert {:error, :unprocessable_entity, _} =
             Sync.write_file(vault, user, %{"path" => "x.md"}, source("x"))
  end

  test "moving a file renames it without new bytes; to another board it is copied there",
       %{vault: vault, user: user, jobs: jobs} do
    entry = put!(vault, user, "a.pdf", "bytes")

    {:ok, moved} =
      Sync.move_file(vault, user, entry.id, %{"path" => "Docs/b.pdf", "base" => entry.hash})

    assert moved.path == "Docs/b.pdf"
    assert Repo.get!(WikiFile, entry.id).name == "b.pdf"

    {:ok, across} =
      Sync.move_file(vault, user, entry.id, %{"path" => "Jobs/b.pdf", "base" => entry.hash})

    assert across.replaced == entry.id
    assert Repo.get!(WikiFile, across.id).board_id == jobs.id
    assert File.read!(Files.disk_path(Repo.get!(WikiFile, across.id))) == "bytes"
    assert Repo.get!(WikiFile, entry.id).archived_at
  end

  test "a deleted file is archived, guarded by its base, and the feed says so",
       %{vault: vault, user: user} do
    entry = put!(vault, user, "a.pdf", "bytes")
    %{cursor: cursor} = Changes.since(vault, nil, user)

    assert {:error, :conflict, _} = Sync.archive_file(vault, user, entry.id, "stale")
    assert {:ok, %{archived: true}} = Sync.archive_file(vault, user, entry.id, entry.hash)
    assert Sync.listing(vault, user).entries == []

    assert %{changes: [%{subject: "file", action: "archived", name: "a.pdf"}]} =
             Changes.since(vault, cursor, user)
  end

  test "two files of one name in one folder are told apart by the later one's id",
       %{vault: vault, user: user, kb: kb} do
    {:ok, first} = Files.create(kb, %{name: "x.png"}, source("1"))
    {:ok, second} = Files.create(kb, %{name: "x.png"}, source("2"))
    layout = Layout.build(vault)

    assert layout.files[first.id].path == "x.png"
    assert layout.files[second.id].path == "x-F#{second.id}.png"
    assert user
  end

  test "deleting a board takes its files' bytes with it", %{kb: kb} do
    {:ok, file} = Files.create(kb, %{name: "x.bin"}, source("bytes"))
    keys = Slipdock.Boards.file_keys(from(b in Slipdock.Boards.Board, where: b.id == ^kb.id))
    assert file.key in keys
  end

  test "files count against the board owner's storage and items", %{user: user, kb: kb} do
    before = Quota.used(user, :storage)
    {:ok, _} = Files.create(kb, %{name: "x.bin"}, source(String.duplicate("a", 1000)))
    assert Quota.used(user, :storage) == before + 1000
    assert Quota.used(user, :files) == 1
  end

  test "![[name]] draws an image, links anything else, and leaves a missing one as written",
       %{user: user, kb: kb, jobs: jobs} do
    {:ok, image} = Files.create(jobs, %{name: "Chart.png"}, source("png"))
    {:ok, pdf} = Files.create(kb, %{name: "Spec.pdf"}, source("pdf"))
    {:ok, page} = Wiki.create_page(kb, %{"title" => "Note"})

    html =
      Renderer.to_html("![[chart.png]]\n\n![[Spec.pdf|the spec]]\n\n![[Ghost.png]]",
        page: page,
        as: user
      )

    assert html =~ ~s(<img class="wiki-file-embed" src="/wiki-files/#{image.id}/Chart.png")

    assert html =~
             ~r{<a class="wiki-file-link" href="/wiki-files/#{pdf.id}/Spec.pdf"[^>]*>the spec</a>}

    assert html =~ "![[Ghost.png]]"

    inline = Renderer.to_html("See ![[chart.png]] here.", page: page, as: user)
    assert inline =~ ~s(See <img class="wiki-file-embed" src="/wiki-files/#{image.id}/Chart.png")
    assert inline =~ "here."
  end

  test "resolving prefers the page's own board, narrows by folder, and hides what can't be read",
       %{user: user, kb: kb, jobs: jobs} do
    {:ok, theirs} = Files.create(jobs, %{name: "x.png"}, source("j"))
    {:ok, folder} = Wiki.create_folder(kb, %{"name" => "Img"})
    {:ok, own} = Files.create(kb, %{name: "x.png", folder_id: folder.id}, source("k"))

    assert Files.resolve(kb, "x.png", user).id == own.id
    assert Files.resolve(jobs, "x.png", user).id == theirs.id
    assert Files.resolve(jobs, "Img/x.png", user).id == own.id
    assert Files.resolve(kb, "Other/x.png", user) == nil
    assert Files.resolve(kb, "x.png", user_fixture("stranger@example.com")) == nil
  end
end
