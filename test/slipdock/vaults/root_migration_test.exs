defmodule Slipdock.Vaults.RootMigrationTest do
  @moduledoc "The move to one root vault (#1596), on the shapes prod has."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Vaults.{Layout, RootMigration, RootReport, Vault}
  alias Slipdock.Wiki.{Folder, Page, Revision}

  setup do
    user = user_fixture("root.migration@example.com")
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "rmkb"}, owner: user)
    jobs = board_fixture(%{"name" => "Employability Ideas", "code" => "rmjobs"}, owner: user)
    %{user: user, kb: kb, jobs: jobs}
  end

  defp old_vault!(user, name, attrs \\ %{}) do
    {:ok, vault} =
      %Vault{user_id: user.id}
      |> Vault.changeset(%{"name" => name})
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert()

    vault
  end

  defp map!(vault, board, path, folder \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("vault_mappings", [
      %{
        vault_id: vault.id,
        board_id: board.id,
        folder_id: folder && folder.id,
        path: path,
        inside: false,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp gminds(ctx) do
    vault = old_vault!(ctx.user, "GMinds")
    map!(vault, ctx.kb, "")
    map!(vault, ctx.jobs, "Jobs")
    vault
  end

  defp page!(board, user, title, attrs \\ %{}) do
    {:ok, page} =
      Wiki.create_page(board, Map.merge(%{"title" => title, "body" => "x"}, attrs), user: user)

    page
  end

  defp snapshot do
    %{
      vaults: Repo.aggregate(Vault, :count),
      mappings: Repo.aggregate("vault_mappings", :count),
      pages:
        Repo.all(from(p in Page, order_by: p.id, select: {p.id, p.folder_id, p.title, p.body})),
      cards: Repo.all(from(c in Card, order_by: c.id, select: {c.id, c.description})),
      folders: Repo.aggregate(Folder, :count)
    }
  end

  defp run(user, opts \\ []) do
    RootMigration.run(Repo.get!(User, user.id), opts)
  end

  describe "vaults" do
    test "two become one, carrying what hangs off them", ctx do
      gone = old_vault!(ctx.user, "Old", %{recordings_folder: "Recordings", position: 4})
      map!(gone, ctx.jobs, "Jobs")
      kept = old_vault!(ctx.user, "Main")
      map!(kept, ctx.kb, "")
      map!(kept, ctx.kb, "Deep", folder!(ctx.kb, "Deep"))

      report = run(ctx.user)
      assert report.vault.kept == kept.id
      assert report.vault.merged == [gone.id]

      assert [%Vault{id: id} = vault] =
               Repo.all(from(v in Vault, where: v.user_id == ^ctx.user.id))

      assert id == kept.id
      assert vault.recordings_folder == "Recordings"
      assert vault.position == 4

      assert Repo.aggregate(from(m in "vault_mappings", where: m.vault_id == ^id), :count) == 0
    end

    test "the quick-note vault survives, and its location is pointed anew", ctx do
      other = old_vault!(ctx.user, "Bigger")
      map!(other, ctx.jobs, "")
      map!(other, ctx.jobs, "A", folder!(ctx.jobs, "A"))
      notes = folder!(ctx.kb, "Inbox")
      vault = old_vault!(ctx.user, "Notes")
      map!(vault, ctx.kb, "")

      ctx.user
      |> Ecto.Changeset.change(quick_note_vault_id: vault.id, quick_note_folder: "Inbox")
      |> Repo.update!()

      assert run(ctx.user).vault.kept == vault.id
      assert notes.id

      user = Repo.get!(User, ctx.user.id)
      assert user.quick_note_vault_id == vault.id
      assert user.quick_note_folder == "KnowledgeBase/Inbox"
    end

    test "mirrors come across, a clash keeping the survivor's", ctx do
      Slipdock.Accounts.create_api_token(ctx.user, "sync")

      token =
        Repo.one!(
          from(t in "users_tokens",
            where: t.user_id == ^ctx.user.id and t.context == "api",
            select: t.id
          )
        )

      from_vault = old_vault!(ctx.user, "A")
      to_vault = old_vault!(ctx.user, "B")
      map!(to_vault, ctx.kb, "")
      Vaults.touch_mirror(from_vault, %{id: token, label: "laptop"})
      Vaults.touch_mirror(to_vault, %{id: token, label: "survivor"})

      run(ctx.user)

      assert [%{label: "survivor"}] = Vaults.mirrors(to_vault)
    end

    test "a person with boards and no vault gets one", ctx do
      assert %{vault: %{kept: id, merged: []}} = run(ctx.user)
      assert Repo.get!(Vault, id).user_id == ctx.user.id
    end
  end

  describe "renames" do
    test "the board's name changes and its code stays", ctx do
      gminds(ctx)
      page = page!(ctx.kb, ctx.user, "Note")

      report = run(ctx.user, rename: %{"rmkb" => "GMinds"})

      assert report.renamed == [%{code: "rmkb", from: "KnowledgeBase", to: "GMinds"}]
      assert report.new_paths.pages[page.id] == "GMinds/Note.md"
    end

    test "someone else's board of that code is left alone", ctx do
      gminds(ctx)
      assert run(ctx.user, rename: %{"nosuch" => "GMinds"}).renamed == []
    end
  end

  describe "card pages" do
    setup ctx do
      gminds(ctx)
      %{card: card_fixture(hd(ctx.kb.columns), %{"title" => "The card"})}
    end

    test "a loose page goes to its card's folder", ctx do
      page = page!(ctx.kb, ctx.user, "Loose")
      {:ok, _} = Wiki.pin(page, {:card, ctx.card})

      report = run(ctx.user)

      assert report.new_paths.pages[page.id] == "KnowledgeBase/Cards/The card/Loose.md"
      assert [%{from: nil}] = report.moved.moved
    end

    test "so does one in a folder", ctx do
      folder = folder!(ctx.kb, "Loop logs")
      page = page!(ctx.kb, ctx.user, "Filed", %{"folder_id" => folder.id})
      {:ok, _} = Wiki.pin(page, {:card, ctx.card})

      assert [%{from: "Loop logs"}] = run(ctx.user).moved.moved
      assert Repo.get!(Folder, Repo.get!(Page, page.id).folder_id).card_id == ctx.card.id
    end

    test "a cross-board pin stays a link", ctx do
      page = page!(ctx.jobs, ctx.user, "Elsewhere")
      {:ok, _} = Wiki.pin(page, {:card, ctx.card})

      report = run(ctx.user)

      assert report.moved.moved == []
      assert report.moved.cross_board == 1
      assert Repo.get!(Page, page.id).folder_id == nil
    end

    test "a page on two cards goes to the first", ctx do
      other = card_fixture(hd(ctx.kb.columns), %{"title" => "Second"})
      page = page!(ctx.kb, ctx.user, "Both")
      {:ok, _} = Wiki.pin(page, {:card, ctx.card})
      {:ok, _} = Wiki.pin(page, {:card, other})

      report = run(ctx.user)

      assert [%{card_id: id}] = report.moved.moved
      assert id == ctx.card.id
      assert report.moved.second_pins == 1
    end

    test "a pinned child stays under its parent", ctx do
      parent = page!(ctx.kb, ctx.user, "Parent")
      child = page!(ctx.kb, ctx.user, "Child", %{"parent_id" => parent.id})
      {:ok, _} = Wiki.pin(child, {:card, ctx.card})

      report = run(ctx.user)

      assert report.moved.children == 1
      assert Repo.get!(Page, child.id).parent_id == parent.id
      assert report.new_paths.pages[child.id] == "KnowledgeBase/Parent/Child.md"
    end

    test "kept folders are left, and named in the report", ctx do
      top = folder!(ctx.kb, "Handbook")
      {:ok, deep} = Wiki.create_folder(ctx.kb, %{"name" => "Decisions", "parent_id" => top.id})
      page = page!(ctx.kb, ctx.user, "Why", %{"folder_id" => deep.id})
      {:ok, _} = Wiki.pin(page, {:card, ctx.card})

      report = run(ctx.user, keep_folders: ["handbook"])

      assert report.moved.moved == []
      assert [%{folder: "Handbook/Decisions"}] = report.moved.kept
      assert Repo.get!(Page, page.id).folder_id == deep.id
    end

    test "a page kept by its code stays with no folder, whatever the case", ctx do
      page = page!(ctx.kb, ctx.user, "Loose spec")
      other = page!(ctx.kb, ctx.user, "Loose note")
      {:ok, _} = Wiki.pin(page, {:card, ctx.card})
      {:ok, _} = Wiki.pin(other, {:card, ctx.card})

      report = run(ctx.user, keep_pages: [String.downcase(page.code)])

      assert [%{code: code, folder: nil}] = report.moved.kept
      assert code == page.code
      assert Repo.get!(Page, page.id).folder_id == nil
      assert [%{page_id: moved}] = report.moved.moved
      assert moved == other.id
    end

    test "an archived card keeps its pages' folder; an archived page stays", ctx do
      page = page!(ctx.kb, ctx.user, "On archived")
      gone = page!(ctx.kb, ctx.user, "Archived page")
      {:ok, _} = Wiki.pin(page, {:card, ctx.card})
      {:ok, _} = Wiki.pin(gone, {:card, ctx.card})
      {:ok, _} = Wiki.archive_page(gone)
      {:ok, _} = Slipdock.Boards.archive_card(ctx.card)

      run(ctx.user)

      assert Repo.get!(Page, page.id).folder_id
      assert Repo.get!(Page, gone.id).folder_id == nil
    end
  end

  describe "pass logs" do
    test "take their new titles", ctx do
      gminds(ctx)
      page = page!(ctx.kb, ctx.user, "Pass log #775: Fix it (2026-10-18 01:09)")

      report = run(ctx.user)

      assert [%{to: title}] = report.titles
      assert title =~ "Pass 775"
      assert Repo.get!(Page, page.id).title == title
    end
  end

  describe "links" do
    setup ctx do
      gminds(ctx)
      {:ok, archive} = Wiki.create_folder(ctx.jobs, %{"name" => "Archive"})
      target = page!(ctx.jobs, ctx.user, "Status", %{"folder_id" => archive.id})
      %{target: target}
    end

    test "an absolute path through the old mount is rewritten, verified", ctx do
      note = page!(ctx.kb, ctx.user, "Note", %{"body" => "See [[Jobs/Archive/Status|it]]."})

      report = run(ctx.user)
      page = Repo.get!(Page, note.id)

      assert [%{rewrite: rewrite}] = report.rewrites
      assert rewrite == "[[Employability Ideas/Archive/Status|it]]"
      assert page.body == "See [[Employability Ideas/Archive/Status|it]]."
      assert report.check.links_lost == []

      assert Repo.exists?(
               from(r in Revision,
                 where: r.page_id == ^note.id and r.summary == "migration: link rewrite"
               )
             )
    end

    test "a relative path climbing through the mount is rewritten", ctx do
      folder = folder!(ctx.kb, "Deep")

      note =
        page!(ctx.kb, ctx.user, "Rel", %{
          "body" => "[[../Jobs/Archive/Status]]",
          "folder_id" => folder.id
        })

      report = run(ctx.user)

      assert [%{rewrite: "[[Employability Ideas/Archive/Status]]"}] = report.rewrites
      assert Repo.get!(Page, note.id).body == "[[Employability Ideas/Archive/Status]]"
    end

    test "card descriptions and comments are rewritten too", ctx do
      card =
        card_fixture(hd(ctx.kb.columns), %{"description" => "[[Jobs/Archive/Status]]"})

      {:ok, comment} =
        %Comment{card_id: card.id, user_id: ctx.user.id}
        |> Comment.changeset(%{"body" => "and [[Jobs/Archive/Status]]", "card_id" => card.id})
        |> Repo.insert()

      run(ctx.user)

      assert Repo.get!(Card, card.id).description == "[[Employability Ideas/Archive/Status]]"
      assert Repo.get!(Comment, comment.id).body == "and [[Employability Ideas/Archive/Status]]"
    end

    test "a link still finding its page is left exactly as written", ctx do
      note = page!(ctx.kb, ctx.user, "Plain", %{"body" => "[[Status]] and [[Archive/Status]]"})

      assert run(ctx.user).rewrites == []
      assert Repo.get!(Page, note.id).body == "[[Status]] and [[Archive/Status]]"
    end

    test "one that can't be verified is left alone and reported", ctx do
      # Same path in two places the rewrite can't tell apart: a title of `.`
      # cleans to nothing, so no written path comes back to it.
      odd = page!(ctx.jobs, ctx.user, "###")
      assert odd.id
      note = page!(ctx.kb, ctx.user, "Odd", %{"body" => "[[Jobs/#{odd.slug}]]"})

      report = run(ctx.user)

      assert [%{rewrite: nil}] = report.rewrites
      assert Repo.get!(Page, note.id).body == "[[Jobs/#{odd.slug}]]"
      assert [%{source: {:page, id}}] = report.check.links_lost
      assert id == note.id
    end
  end

  describe "the run" do
    setup ctx do
      gminds(ctx)
      card = card_fixture(hd(ctx.kb.columns), %{"title" => "Pinned"})
      {:ok, archive} = Wiki.create_folder(ctx.jobs, %{"name" => "Archive"})
      page!(ctx.jobs, ctx.user, "Status", %{"folder_id" => archive.id})
      pinned = page!(ctx.kb, ctx.user, "Pass log #9: Thing (2026-10-18 01:09)")
      {:ok, _} = Wiki.pin(pinned, {:card, card})
      page!(ctx.kb, ctx.user, "Note", %{"body" => "[[Jobs/Archive/Status]]"})
      :ok
    end

    test "a dry run reports all of it and changes nothing", ctx do
      before = snapshot()

      report = run(ctx.user, dry_run: true, rename: %{"rmkb" => "GMinds"})

      assert length(report.moved.moved) == 1
      assert length(report.titles) == 1
      assert length(report.rewrites) == 1
      assert snapshot() == before
    end

    test "running it twice changes nothing the second time", ctx do
      first = run(ctx.user, rename: %{"rmkb" => "GMinds"})
      after_first = snapshot()
      second = run(ctx.user, rename: %{"rmkb" => "GMinds"})

      assert length(first.moved.moved) == 1
      assert second.moved.moved == []
      assert second.titles == []
      assert second.rewrites == []
      assert second.renamed == []
      assert second.vault.merged == []
      assert snapshot() == after_first
    end

    test "every page has a path afterwards", ctx do
      archived = board_fixture(%{"name" => "Old board", "code" => "rmold"}, owner: ctx.user)
      page!(archived, ctx.user, "Kept")
      {:ok, _} = Slipdock.Boards.archive_board(archived)

      %{check: check} = run(ctx.user)

      assert check.pages_placed == check.pages_live
    end

    test "the report's files hold what happened", ctx do
      dir = Path.join(System.tmp_dir!(), "root-report-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      report = run(ctx.user, dry_run: true)

      summary = RootReport.write(%{users: [report], short_names: %{}, dry_run: true}, dir)

      assert [%{links_rewritten: 1, links_not_verified: 0, card_pages_moved: 1}] = summary.users

      assert File.read!(Path.join(dir, "user-#{ctx.user.id}-link-rewrites.tsv")) =~
               "Employability Ideas/Archive/Status"

      assert File.exists?(Path.join(dir, "summary.exs"))
    end

    test "a run for everyone fills in short names, and a dry run doesn't", ctx do
      long = card_fixture(hd(ctx.kb.columns), %{"title" => String.duplicate("word ", 12)})
      Repo.update_all(from(c in Card, where: c.id == ^long.id), set: [short_name: nil])

      dry = RootMigration.run_all(dry_run: true, user_ids: [ctx.user.id])
      assert dry.short_names.named >= 1
      assert Repo.get!(Card, long.id).short_name == nil

      RootMigration.run_all(model: false, user_ids: [ctx.user.id])
      assert Repo.get!(Card, long.id).short_name
    end
  end

  test "the layout after it holds every board", ctx do
    gminds(ctx)
    other = board_fixture(%{"name" => "Never mapped", "code" => "rmnew"}, owner: ctx.user)
    page = page!(other, ctx.user, "Now seen")

    report = run(ctx.user)

    assert report.new_paths.pages[page.id] == "Never mapped/Now seen.md"
    assert report.old_paths.pages[page.id] == "Never mapped/Now seen.md"
    assert Layout.boards(Vaults.root(ctx.user)) |> length() == 3
  end

  defp folder!(board, name) do
    {:ok, folder} = Wiki.create_folder(board, %{"name" => name})
    folder
  end
end
