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
    kb = board_fixture(%{"name" => "Keystone", "code" => "kb"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobs"}, owner: user)
    {:ok, notes} = Wiki.create_folder(jobs, %{"name" => "Notes"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: jobs, folder: notes})
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
      page!(jobs, %{"title" => "Launch", "folder_id" => acme.id})
      # Not under the mapped folder, so in no vault path at all.
      page!(jobs, %{"title" => "Elsewhere"})

      assert paths(vault) ==
               [
                 "Deploys/Rollback.md",
                 "Deploys/index.md",
                 "Journal/Acme/Launch.md",
                 "Journal/Call.md",
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
      jobs_page = page!(kb, %{"title" => "Journal"})
      page!(kb, %{"title" => "Child", "parent_id" => jobs_page.id})
      layout = Layout.build(vault)

      assert layout.pages[jobs_page.id].path == "Journal-#{jobs_page.code}/index.md"
    end

    test "a path's place: beside a page's index, in a mapping's folders, or nowhere",
         %{vault: vault, kb: kb, user: user, jobs: jobs} do
      deploys = page!(kb, %{"title" => "Deploys"})
      page!(kb, %{"title" => "Rollback", "parent_id" => deploys.id})
      layout = Layout.build(vault)

      assert {:parent, id} = Layout.place(layout, "Deploys/New.md")
      assert id == deploys.id
      assert {:error, _} = Layout.place(layout, "Deploys/Sub/New.md")

      assert {:folder, %{board_id: board_id}, ["Acme"]} =
               Layout.place(layout, "journal/Acme/x.md")

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

  describe "listing folders" do
    test "every folder as a directory, empty ones too, and none outside the vault",
         %{vault: vault, user: user, kb: kb, jobs: jobs, notes: notes} do
      {:ok, design} = Wiki.create_folder(kb, %{"name" => "Design"})
      {:ok, _} = Wiki.create_folder(kb, %{"name" => "Old", "parent_id" => design.id})
      {:ok, _} = Wiki.create_folder(jobs, %{"name" => "Acme", "parent_id" => notes.id})
      # Not under the mapped folder, so in no vault path at all.
      {:ok, _} = Wiki.create_folder(jobs, %{"name" => "Elsewhere"})

      assert Sync.listing(vault, user).folders == [
               "Design",
               "Design/Old",
               "Journal",
               "Journal/Acme"
             ]
    end

    test "a deleted folder leaves the listing",
         %{vault: vault, user: user, kb: kb} do
      {:ok, design} = Wiki.create_folder(kb, %{"name" => "Design"})
      assert "Design" in Sync.listing(vault, user).folders

      {:ok, _} = Wiki.Folders.delete(design)
      refute "Design" in Sync.listing(vault, user).folders
    end

    test "only the folders of boards the reader may open",
         %{vault: vault, user: user, kb: kb, jobs: jobs, notes: notes} do
      {:ok, _} = Wiki.create_folder(kb, %{"name" => "Design"})
      {:ok, _} = Wiki.create_folder(jobs, %{"name" => "Acme", "parent_id" => notes.id})

      assert Sync.listing(vault, user_fixture("stranger@example.com")).folders == []

      token = %{scope: "write", scope_boards: [jobs.id]}
      assert Sync.listing(vault, user, token: token).folders == ["Journal", "Journal/Acme"]
    end
  end

  describe "writing" do
    test "a new file is a new page, its folders made, its name its title",
         %{vault: vault, user: user, jobs: jobs, notes: notes} do
      content = "---\nrating: 5 # out of five\n---\n\nIt went well.\n"

      assert {:ok, entry} =
               Sync.write_page(vault, user, %{
                 "path" => "Journal/Acme/Call.md",
                 "content" => content
               })

      page = Repo.get!(Page, entry.id)
      assert page.title == "Call"
      assert page.board_id == jobs.id
      assert Wiki.folder_path(Slipdock.Wiki.Folders.get!(page.folder_id)) == "Notes/Acme"
      assert Slipdock.Wiki.Folders.get!(page.folder_id).parent_id == notes.id
      assert page.body == "It went well.\n"
      assert entry.path == "Journal/Acme/Call.md"
      # Nothing to patch, so the server writes back exactly what was sent.
      assert entry.content == content
      assert entry.hash == Sync.hash(content)

      revision = page |> Wiki.list_revisions() |> hd()
      assert revision.via == "sync"
    end

    test "a second file in the same new directory finds the folder rather than making another",
         %{vault: vault, user: user, jobs: jobs} do
      {:ok, a} = Sync.write_page(vault, user, %{"path" => "Journal/Acme/A.md", "content" => "a"})
      {:ok, b} = Sync.write_page(vault, user, %{"path" => "Journal/acme/B.md", "content" => "b"})

      assert Repo.get!(Page, a.id).folder_id == Repo.get!(Page, b.id).folder_id
      assert b.path == "Journal/Acme/B.md"
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
          "path" => "Journal/Note.md",
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
                 "path" => "Journal/Deploys/index.md",
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

  describe "also-in (R12.5)" do
    alias Slipdock.Wiki.Placements

    test "a page filed in other folders says so in front matter, by vault path, and only those in the vault",
         %{vault: vault, user: user, kb: kb, jobs: jobs, notes: notes} do
      {:ok, ideas} = Wiki.create_folder(kb, %{"name" => "Ideas"})
      {:ok, outside} = Wiki.create_folder(jobs, %{"name" => "Elsewhere"})
      page = page!(kb, %{"title" => "Plan", "body" => "b"})
      %{entries: [%{hash: before}]} = Sync.listing(vault, user)

      {:ok, _} = Placements.add(page, ideas, user)
      {:ok, _} = Placements.add(page, notes, user)
      {:ok, _} = Placements.add(page, outside, user)

      {:ok, %{content: content, hash: hash}} = Sync.read_page(vault, user, page.id)
      assert content == "---\nalso-in: [Ideas, Journal]\n---\n\nb"
      # Filing it elsewhere changed its file, so a sync brings it down again.
      refute hash == before
      assert [%{hash: ^hash}] = Sync.listing(vault, user).entries
    end

    test "editing also-in in the file changes the placements, folders made as needed",
         %{vault: vault, user: user, kb: kb, jobs: jobs} do
      {:ok, outside} = Wiki.create_folder(jobs, %{"name" => "Elsewhere"})
      {:ok, ideas} = Wiki.create_folder(kb, %{"name" => "Ideas"})
      page = page!(kb, %{"title" => "Plan", "body" => "b"})
      {:ok, _} = Placements.add(page, ideas, user)
      {:ok, _} = Placements.add(page, outside, user)
      {:ok, %{hash: base}} = Sync.read_page(vault, user, page.id)

      sent = "---\nalso-in: [Journal/Acme, Later]\n---\n\nb"

      {:ok, entry} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "Plan.md",
          "content" => sent,
          "base" => base
        })

      paths =
        page
        |> Placements.folders()
        |> Enum.map(&{&1.board_id, Wiki.folder_path(&1)})
        |> Enum.sort()

      # Ideas is gone; Acme (under Notes, which /Journal maps) and Later (on kb)
      # are new; the folder outside the vault's paths was not the file's to touch.
      assert paths ==
               Enum.sort([{jobs.id, "Elsewhere"}, {jobs.id, "Notes/Acme"}, {kb.id, "Later"}])

      assert entry.content == sent
      assert entry.hash == Sync.hash(sent)
    end

    test "a new note can be filed in several folders from the start, and its home is never one",
         %{vault: vault, user: user} do
      sent = "---\nalso-in: [Ideas, Projects]\n---\n\nb"
      {:ok, entry} = Sync.write_page(vault, user, %{"path" => "Ideas/Plan.md", "content" => sent})

      page = Repo.get!(Page, entry.id)
      assert page |> Placements.folders() |> Enum.map(&Wiki.folder_path/1) == ["Projects"]
      # The home folder isn't a placement, so the file the server writes says only the other.
      assert entry.content == "---\nalso-in: [Projects]\n---\n\nb"
    end

    test "taking also-in out takes the placements in the vault away, and the key stays out",
         %{vault: vault, user: user, kb: kb} do
      {:ok, ideas} = Wiki.create_folder(kb, %{"name" => "Ideas"})
      page = page!(kb, %{"title" => "Plan", "body" => "b"})
      {:ok, _} = Placements.add(page, ideas, user)
      {:ok, %{hash: base}} = Sync.read_page(vault, user, page.id)

      {:ok, entry} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "Plan.md",
          "content" => "b",
          "base" => base
        })

      assert Placements.folders(page) == []
      assert entry.content == "b"
    end
  end

  describe "an Obsidian vault imported (R9.2)" do
    # What `slipdock vault import` sends is the file as it is on disk; the
    # server must hand the same bytes back, or a later `sync init` would
    # see every note as changed on both sides.
    @samples %{
      "Front matter.md" =>
        "---\n# kept\nzeta: 1\ntags: [a, b]\naliases:\n  - Other name\nalpha: \"two\"\n---\nBody with #tag and [[Link]]\n",
      "Drawing.excalidraw.md" =>
        "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠==\n\n# Text Elements\nHello ^abc123\n\n%%\n# Drawing\n```compressed-json\nN4KAkARALgngDgUwgLgAQQQDwMYEMA2AlgCYBOuA7hADTgQBuCpAzoQPYB2KqATLZMzYBXUtiRoIACyhQ4zZAHoFAc0JRJQgEYA6bGwC2CgF7N6hbEcK4OCtptbErHALRY8RMpWdx8Q1TdIEfARcZgRmBShcZQUebQBGAHZ4mjoghH0EDihmbgBtcDBQMBKIEm4IAElUyTQAawQcmQBGfQBhJlZURtwATgAOfQA5TrSq3QAFeXbS9g72Wt0hiF\n```\n%%\n",
      "Secret.md" => "Before %%🔐β Y2lwaGVydGV4dA== 🔐%% after\n",
      "No newline at end.md" => "just text"
    }

    test "a note's file is the bytes it was imported from", %{vault: vault, user: user} do
      for {path, content} <- @samples do
        {:ok, written} = Sync.write_page(vault, user, %{"path" => path, "content" => content})
        assert written.path == path
        assert written.content == content, "#{path} came back changed"
        assert written.hash == Sync.hash(content)
      end

      listed = Sync.listing(vault, user).entries |> Map.new(&{&1.path, &1.hash})
      for {path, content} <- @samples, do: assert(listed[path] == Sync.hash(content))
    end

    test "a summary too long to be the page's stays the writer's own key, byte for byte",
         %{vault: vault, user: user} do
      long = String.duplicate("A clipped paragraph. ", 20)

      content =
        "---\ntitle: \"Clipped\"\nauthor:\n  - \"[[Someone]]\"\npublished:\nsummary: \"#{long}\"\n---\nBody\n"

      assert {:ok, written} =
               Sync.write_page(vault, user, %{
                 "path" => "Clippings/Clipped.md",
                 "content" => content
               })

      assert written.content == content
      assert Repo.get!(Page, written.id).summary == nil

      short = "---\nsummary: Short and sweet\n---\nBody\n"
      {:ok, written} = Sync.write_page(vault, user, %{"path" => "Short.md", "content" => short})
      assert written.content == short
      assert Repo.get!(Page, written.id).summary == "Short and sweet"
    end

    test "a summary cleared in the app leaves a long summary key alone, and takes a short one out",
         %{kb: kb} do
      long = String.duplicate("x", 301)
      page = page!(kb, %{"title" => "Long", "front_matter" => "---\nsummary: #{long}\n---\n"})
      assert Archive.sync_file(page) =~ "summary: #{long}"

      page = page!(kb, %{"title" => "Short", "front_matter" => "---\nsummary: old\n---\n"})
      refute Archive.sync_file(%{page | summary: nil}) =~ "summary"
    end

    test "a note in a mapped folder lands on that board", %{vault: vault, user: user, jobs: jobs} do
      {:ok, written} =
        Sync.write_page(vault, user, %{"path" => "Journal/Acme/Launch.md", "content" => "offer"})

      assert written.board_id == jobs.id
      assert written.content == "offer"
    end
  end

  describe "an imported note keeps its file name (R9)" do
    defp write!(vault, user, path, content) do
      {:ok, entry} = Sync.write_page(vault, user, %{"path" => path, "content" => content})
      entry
    end

    test "a note whose front matter gives it another title stays where it was, and links find it",
         %{vault: vault, user: user} do
      content = "---\ntitle: \"CTO Candidate Interview: David\"\n---\nNotes\n"
      entry = write!(vault, user, "Meetings/2026-03-05 CTO-Candidate-Interview-David.md", content)

      assert entry.path == "Meetings/2026-03-05 CTO-Candidate-Interview-David.md"
      assert entry.content == content
      page = Repo.get!(Page, entry.id)
      assert page.title == "CTO Candidate Interview: David"
      assert page.file_name == "2026-03-05 CTO-Candidate-Interview-David"

      index = Slipdock.Vaults.Index.build(vault)

      assert [%{id: id}] =
               Slipdock.Vaults.Index.match(index, "2026-03-05 CTO-Candidate-Interview-David")

      assert id == entry.id
      assert [%{id: ^id}] = Slipdock.Vaults.Index.match(index, "CTO Candidate Interview: David")
    end

    test "a trailing space or a name over 80 characters is kept, and no title key is added",
         %{vault: vault, user: user} do
      spaced = write!(vault, user, "Meetings/2025-05-13 13-01 Catchup .md", "Catch up\n")
      assert spaced.path == "Meetings/2025-05-13 13-01 Catchup .md"
      assert spaced.content == "Catch up\n"
      assert Repo.get!(Page, spaced.id).title == "2025-05-13 13-01 Catchup"

      name =
        "2025-04-24 14-31 Atheneum  McKinsey - Maintaining high quality service delivery in lieu"

      assert String.length(name) > 80
      long = write!(vault, user, name <> ".md", "Long\n")
      assert long.path == name <> ".md"
      assert long.content == "Long\n"

      # Listed the same way, so a sync sees nothing to do.
      listed = Sync.listing(vault, user).entries |> Map.new(&{&1.id, &1.path})
      assert listed[spaced.id] == spaced.path
      assert listed[long.id] == long.path
    end

    test "an empty title key and a note that is only a blank line come back as they went",
         %{vault: vault, user: user} do
      templated = "---\ntitle:\ntags: [daily]\n---\nToday\n"
      assert write!(vault, user, "Daily/2025-02-27.md", templated).content == templated
      assert write!(vault, user, "Tasks/Inbox.md", "\n").content == "\n"
    end

    test "renamed in the app, the file follows the new title", %{vault: vault, user: user} do
      entry = write!(vault, user, "Catchup .md", "x\n")
      page = Repo.get!(Page, entry.id)

      {:ok, page} = Wiki.update_page(page, %{"title" => "Weekly catch-up"})

      assert page.file_name == nil
      {:ok, read} = Sync.read_page(vault, user, page.id)
      assert read.path == "Weekly catch-up.md"
    end

    test "an edit that keeps the title keeps the file name", %{vault: vault, user: user} do
      entry = write!(vault, user, "Catchup .md", "x\n")
      page = Repo.get!(Page, entry.id)

      {:ok, page} = Wiki.update_page(page, %{"body" => "y\n"})
      assert page.file_name == "Catchup "

      {:ok, again} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "Catchup .md",
          "content" => "z\n",
          "base" => Sync.hash("y\n")
        })

      assert again.path == "Catchup .md"
      assert Repo.get!(Page, page.id).file_name == "Catchup "
    end

    test "a file renamed here to a name its title can't give keeps that name",
         %{vault: vault, user: user, kb: kb} do
      page = page!(kb, %{"title" => "Plain", "body" => "b"})
      {:ok, %{hash: base}} = Sync.read_page(vault, user, page.id)

      {:ok, entry} =
        Sync.write_page(vault, user, %{
          "id" => page.id,
          "path" => "Plain renamed .md",
          "content" => "b",
          "base" => base
        })

      assert entry.path == "Plain renamed .md"
      assert Repo.get!(Page, page.id).title == "Plain renamed"
    end

    test "a file name can't hold a slash" do
      changeset = Page.changeset(%Page{}, %{"title" => "T", "file_name" => "a/b"})
      assert %{file_name: [_]} = errors_on(changeset)
    end
  end
end
