defmodule Slipdock.Vaults.SyncTest do
  @moduledoc """
  The server half of `slipdock sync` (W-103 R2): a vault laid out as files,
  each with the hash of the bytes a sync writes, and pages written, moved,
  renamed and archived by path, every write checked against a base.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Vaults.{Layout, Sync}
  alias Slipdock.Wiki.{Archive, Page}

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kb"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobs"}, owner: user)
    {:ok, notes} = Wiki.create_folder(jobs, %{"name" => "Notes"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs, folder: notes})
    %{user: user, kb: kb, jobs: jobs, notes: notes, vault: vault}
  end

  defp page!(board, attrs) do
    {:ok, page} = Wiki.create_page(board, attrs)
    page
  end

  defp paths(vault),
    do:
      vault
      |> Layout.build()
      |> Map.fetch!(:pages)
      |> Map.values()
      |> Enum.map(& &1.path)
      |> Enum.sort()

  describe "the layout" do
    test "names files as an export does: safe names, index.md for a page with children",
         %{vault: vault, kb: kb, jobs: jobs, notes: notes} do
      page!(kb, %{"title" => "Retry: why"})
      deploys = page!(kb, %{"title" => "Deploys"})
      page!(kb, %{"title" => "Rollback", "parent_id" => deploys.id})
      page!(jobs, %{"title" => "Call", "folder_id" => notes.id})
      {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme", "parent_id" => notes.id})
      page!(jobs, %{"title" => "Offer", "folder_id" => acme.id})
      # Not under the mapped folder, so in no vault path at all.
      page!(jobs, %{"title" => "Elsewhere"})

      assert paths(vault) ==
               [
                 "Deploys/Rollback.md",
                 "Deploys/index.md",
                 "Jobs/Acme/Offer.md",
                 "Jobs/Call.md",
                 "Retry- why.md"
               ]
    end

    test "two pages wanting one name, case aside, are told apart by the later one's code",
         %{vault: vault, kb: kb} do
      first = page!(kb, %{"title" => "Note", "slug" => "note-1"})
      second = page!(kb, %{"title" => "note", "slug" => "note-2"})
      layout = Layout.build(vault)

      assert layout.pages[first.id].path == "Note.md"
      assert layout.pages[second.id].path == "note-#{second.code}.md"
    end

    test "a page with children does not take a mapping's directory", %{vault: vault, kb: kb} do
      jobs_page = page!(kb, %{"title" => "Jobs"})
      page!(kb, %{"title" => "Child", "parent_id" => jobs_page.id})
      layout = Layout.build(vault)

      assert layout.pages[jobs_page.id].path == "Jobs-#{jobs_page.code}/index.md"
    end

    test "a path's place: beside a page's index, in a mapping's folders, or nowhere",
         %{vault: vault, kb: kb, user: user, jobs: jobs} do
      deploys = page!(kb, %{"title" => "Deploys"})
      page!(kb, %{"title" => "Rollback", "parent_id" => deploys.id})
      layout = Layout.build(vault)

      assert {:parent, id} = Layout.place(layout, "Deploys/New.md")
      assert id == deploys.id
      assert {:error, _} = Layout.place(layout, "Deploys/Sub/New.md")
      assert {:folder, %{board_id: board_id}, ["Acme"]} = Layout.place(layout, "jobs/Acme/x.md")
      assert board_id == jobs.id
      assert {:folder, %{path: ""}, ["Other"]} = Layout.place(layout, "Other/x.md")

      {:ok, only_jobs} = Vaults.create_vault(user, %{"name" => "Only jobs"})
      other = board_fixture(%{"name" => "Other"}, owner: user)
      {:ok, _} = Vaults.add_mapping(only_jobs, user, %{path: "/Work", board: other})
      assert {:error, msg} = only_jobs |> Layout.build() |> Layout.place("Elsewhere/x.md")
      assert msg =~ "nothing in the vault is mapped"
    end
  end

  describe "listing and reading" do
    test "every file with the hash of exactly what sync writes, and a cursor taken first",
         %{vault: vault, user: user, kb: kb} do
      page = page!(kb, %{"title" => "Retry: why", "body" => "Back off.\n"})

      %{cursor: cursor, entries: [entry]} = Sync.listing(vault, user)

      content = Archive.sync_file(Repo.get!(Page, page.id), file_title: "Retry- why")
      assert content =~ ~s(title: "Retry: why")
      assert entry.hash == Sync.hash(content)
      assert entry.path == "Retry- why.md"
      refute Map.has_key?(entry, :content)
      assert is_integer(cursor)

      assert {:ok, %{content: ^content, path: "Retry- why.md"}} =
               Sync.read_page(vault, user, page.id)
    end

    test "leaves out what the reader can't open, and a page outside the vault",
         %{vault: vault, user: user, kb: kb, jobs: jobs} do
      page!(kb, %{"title" => "Mine"})
      outside = page!(jobs, %{"title" => "Outside"})
      stranger = user_fixture("stranger@example.com")

      assert Sync.listing(vault, stranger).entries == []
      assert {:error, :not_found, _} = Sync.read_page(vault, user, outside.id)

      # A token scoped to the jobs board sees nothing of the kb board.
      token = %{scope: "write", scope_boards: [jobs.id]}
      assert Sync.listing(vault, user, token: token).entries == []
    end
  end

  describe "writing" do
    test "a new file is a new page, its folders made, its name its title",
         %{vault: vault, user: user, jobs: jobs, notes: notes} do
      content = "---\nrating: 5 # out of five\n---\n\nIt went well.\n"

      assert {:ok, entry} =
               Sync.write_page(vault, user, %{"path" => "Jobs/Acme/Call.md", "content" => content})

      page = Repo.get!(Page, entry.id)
      assert page.title == "Call"
      assert page.board_id == jobs.id
      assert Wiki.folder_path(Slipdock.Wiki.Folders.get!(page.folder_id)) == "Notes/Acme"
      assert Slipdock.Wiki.Folders.get!(page.folder_id).parent_id == notes.id
      assert page.body == "It went well.\n"
      assert entry.path == "Jobs/Acme/Call.md"
      # Nothing to patch, so the server writes back exactly what was sent.
      assert entry.content == content
      assert entry.hash == Sync.hash(content)

      revision = page |> Wiki.list_revisions() |> hd()
      assert revision.via == "sync"
    end

    test "a second file in the same new directory finds the folder rather than making another",
         %{vault: vault, user: user, jobs: jobs} do
      {:ok, a} = Sync.write_page(vault, user, %{"path" => "Jobs/Acme/A.md", "content" => "a"})
      {:ok, b} = Sync.write_page(vault, user, %{"path" => "Jobs/acme/B.md", "content" => "b"})

      assert Repo.get!(Page, a.id).folder_id == Repo.get!(Page, b.id).folder_id
      assert b.path == "Jobs/Acme/B.md"
      assert length(Wiki.folders(jobs)) == 2
    end

    test "a title a file name can't hold is kept in front matter", %{vault: vault, user: user} do
      {:ok, entry} =
        Sync.write_page(vault, user, %{
          "path" => "Retry- why.md",
          "content" => "---\ntitle: \"Retry: why\"\n---\n\nBody\n"
        })

      assert Repo.get!(Page, entry.id).title == "Retry: why"
      assert entry.path == "Retry- why.md"
    end

    test "a new file where a page already is: a conflict with that page, nothing written",
         %{vault: vault, user: user, kb: kb} do
      page = page!(kb, %{"title" => "Note", "body" => "server"})

      assert {:error, :conflict, current} =
               Sync.write_page(vault, user, %{"path" => "note.md", "content" => "local"})

      assert current.id == page.id
      assert current.content == "server"
      assert Repo.aggregate(Page, :count) == 1
    end

    test "an edit against the right base lands; against a stale one it is a conflict",
         %{vault: vault, user: user, kb: kb} do
      page = page!(kb, %{"title" => "Note", "body" => "one"})
      {:ok, %{hash: base}} = Sync.read_page(vault, user, page.id)

      assert {:ok, entry} =
               Sync.write_page(vault, user, %{
                 "id" => page.id,
                 "path" => "Note.md",
                 "content" => "two",
                 "base" => base
               })

      assert Repo.get!(Page, page.id).body == "two"

      assert {:error, :conflict, current} =
               Sync.write_page(vault, user, %{
                 "id" => page.id,
                 "path" => "Note.md",
                 "content" => "three",
                 "base" => base
               })

      assert current.hash == entry.hash
      assert Repo.get!(Page, page.id).body == "two"
    end

    test "a renamed file renames the page, and a stale title key is patched to match",
         %{vault: vault, user: user, kb: kb} do
      page =
        page!(kb, %{
          "title" => "Old: one",
          "body" => "b",
          "front_matter" => "---\ntitle: \"Old: one\"\n---\n"
        })

      {:ok, %{hash: base, content: content}} = Sync.read_page(vault, user, page.id)

      {:ok, entry} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "New.md",
          "content" => content,
          "base" => base
        })

      assert Repo.get!(Page, page.id).title == "New"
      assert entry.path == "New.md"
      assert entry.content =~ "title: New"
      refute entry.content =~ "Old"
    end

    test "a title changed in front matter, the file not renamed, renames the page and its file",
         %{vault: vault, user: user, kb: kb} do
      page = page!(kb, %{"title" => "Plan", "body" => "b"})
      {:ok, %{hash: base}} = Sync.read_page(vault, user, page.id)

      {:ok, entry} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "Plan.md",
          "content" => "---\ntitle: Roadmap\n---\nb",
          "base" => base
        })

      assert Repo.get!(Page, page.id).title == "Roadmap"
      assert entry.path == "Roadmap.md"
    end

    test "a file moved into another directory refiles the page, or makes it a child",
         %{vault: vault, user: user, kb: kb} do
      page = page!(kb, %{"title" => "Note", "body" => "b"})
      deploys = page!(kb, %{"title" => "Deploys"})
      page!(kb, %{"title" => "Rollback", "parent_id" => deploys.id})
      {:ok, %{hash: base, content: content}} = Sync.read_page(vault, user, page.id)

      {:ok, moved} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "Ideas/Note.md",
          "content" => content,
          "base" => base
        })

      assert moved.path == "Ideas/Note.md"

      assert Wiki.folder_path(Slipdock.Wiki.Folders.get!(Repo.get!(Page, page.id).folder_id)) ==
               "Ideas"

      {:ok, child} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "Deploys/Note.md",
          "content" => content,
          "base" => moved.hash
        })

      assert child.path == "Deploys/Note.md"
      assert Repo.get!(Page, page.id).parent_id == deploys.id
    end

    test "a page's own index.md keeps its title when edited", %{vault: vault, user: user, kb: kb} do
      deploys = page!(kb, %{"title" => "Deploys", "body" => "one"})
      page!(kb, %{"title" => "Rollback", "parent_id" => deploys.id})
      {:ok, %{hash: base}} = Sync.read_page(vault, user, deploys.id)

      {:ok, entry} =
        Sync.write_page(vault, user, %{
          "id" => deploys.id,
          "path" => "Deploys/index.md",
          "content" => "two",
          "base" => base
        })

      assert entry.path == "Deploys/index.md"
      assert %Page{title: "Deploys", body: "two", parent_id: nil} = Repo.get!(Page, deploys.id)
    end

    test "a move under another board's mapping makes the page there and archives this one",
         %{vault: vault, user: user, kb: kb, jobs: jobs} do
      page = page!(kb, %{"title" => "Note", "body" => "b"})
      {:ok, %{hash: base, content: content}} = Sync.read_page(vault, user, page.id)

      {:ok, entry} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "Jobs/Note.md",
          "content" => content,
          "base" => base
        })

      assert entry.replaced == page.id
      assert Repo.get!(Page, entry.id).board_id == jobs.id
      assert Repo.get!(Page, page.id).archived_at
    end

    test "a page with children is not moved between boards by sync",
         %{vault: vault, user: user, kb: kb} do
      deploys = page!(kb, %{"title" => "Deploys"})
      page!(kb, %{"title" => "Rollback", "parent_id" => deploys.id})
      {:ok, %{hash: base, content: content}} = Sync.read_page(vault, user, deploys.id)

      assert {:error, :unprocessable_entity, msg} =
               Sync.write_page(vault, user, %{
                 "id" => deploys.id,
                 "path" => "Jobs/Deploys/index.md",
                 "content" => content,
                 "base" => base
               })

      assert msg =~ "pages under it"
    end

    test "refuses paths that climb, hide or aren't Markdown, and a reader who can't write",
         %{vault: vault, user: user, kb: kb} do
      for path <- ["../x.md", ".obsidian/x.md", "a/.hidden.md", "x.txt", ""] do
        assert {:error, _, _} = Sync.write_page(vault, user, %{"path" => path, "content" => "x"})
      end

      assert {:error, :bad_request, _} = Sync.write_page(vault, user, %{"path" => "x.md"})

      page = page!(kb, %{"title" => "Note"})
      reader = user_fixture("reader@example.com")
      {:ok, _} = Slipdock.Access.grant(kb, reader, "read", user)

      assert {:error, :forbidden, _} =
               Sync.write_page(vault, reader, %{
                 "id" => page.id,
                 "path" => "Note.md",
                 "content" => "x"
               })
    end
  end

  describe "archiving" do
    test "a deleted file archives its page, guarded by its base", %{
      vault: vault,
      user: user,
      kb: kb
    } do
      page = page!(kb, %{"title" => "Note", "body" => "b"})
      {:ok, %{hash: base}} = Sync.read_page(vault, user, page.id)

      assert {:error, :conflict, _} = Sync.archive_page(vault, user, page.id, "stale")
      refute Repo.get!(Page, page.id).archived_at

      assert {:ok, %{archived: true}} = Sync.archive_page(vault, user, page.id, base)
      assert Repo.get!(Page, page.id).archived_at
      assert Sync.listing(vault, user).entries == []
      # Archived, so no longer in the vault to archive again.
      assert {:error, :not_found, _} = Sync.archive_page(vault, user, page.id, nil)
    end
  end
end
