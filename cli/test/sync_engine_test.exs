defmodule SlipdockCLI.SyncEngineTest do
  @moduledoc """
  One pass of `slipdock sync` against an in-memory vault (W-103 R2.2–R2.5):
  both directions, renames kept as the same page, conflicts keeping both
  versions, deletes archiving, and nothing on either side ever lost.
  """
  use ExUnit.Case, async: true

  alias SlipdockCLI.FakeVault
  alias SlipdockCLI.Sync.{Engine, Import, State}

  setup do
    root = Path.join(System.tmp_dir!(), "slipdock-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    vault = FakeVault.start()
    state = State.new("http://test", %{"id" => 1, "name" => "Brain"}, "testhost")
    %{root: root, vault: vault, state: state}
  end

  defp pass(ctx, state \\ nil) do
    {:ok, state, report} =
      Engine.run(ctx.root, state || ctx.state, {FakeVault, ctx.vault},
        host: "testhost",
        today: ~D[2026-10-12]
      )

    {state, report}
  end

  defp write(ctx, path, content) do
    full = Path.join(ctx.root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp read(ctx, path), do: File.read!(Path.join(ctx.root, path))
  defp exists?(ctx, path), do: File.exists?(Path.join(ctx.root, path))

  defp files(ctx) do
    ctx.root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: false)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, ctx.root))
    |> Enum.sort()
  end

  defp quiet?(report),
    do: Enum.all?(report, fn {_kind, items} -> items == [] end)

  test "a first pass brings the vault down, folders and all, and a second does nothing", ctx do
    FakeVault.put(ctx.vault, "Note.md", "one")
    FakeVault.put(ctx.vault, "Journal/Acme/Call.md", "call")

    {state, report} = pass(ctx)

    assert files(ctx) == ["Journal/Acme/Call.md", "Note.md"]
    assert read(ctx, "Journal/Acme/Call.md") == "call"
    assert length(report.received) == 2
    assert %{"id" => _, "hash" => hash} = state["entries"]["Note.md"]
    assert hash == FakeVault.hash("one")
    assert state["cursor"] == 2
    assert state["last_result"]["received"] == 2

    {_state, report} = pass(ctx, state)
    assert quiet?(report)
  end

  test "a new local file becomes a page, then rests", ctx do
    write(ctx, "Ideas/New.md", "fresh")

    {state, report} = pass(ctx)

    assert [%{path: "Ideas/New.md"}] = report.sent
    assert %{content: "fresh"} = FakeVault.by_path(ctx.vault, "Ideas/New.md")

    {_state, report} = pass(ctx, state)
    assert quiet?(report)
  end

  test "an edit goes whichever way it was made, each against its base", ctx do
    id = FakeVault.put(ctx.vault, "Note.md", "one")
    {state, _} = pass(ctx)

    write(ctx, "Note.md", "two, here")
    {state, report} = pass(ctx, state)
    assert [%{path: "Note.md", id: ^id}] = report.sent
    assert FakeVault.pages(ctx.vault)[id].content == "two, here"

    FakeVault.put(ctx.vault, "Note.md", "three, there")
    {_state, report} = pass(ctx, state)
    assert [%{path: "Note.md"}] = report.received
    assert read(ctx, "Note.md") == "three, there"
  end

  test "changed on both sides: the server keeps the path, the local version goes beside it",
       ctx do
    id = FakeVault.put(ctx.vault, "Notes/Plan.md", "base")
    {state, _} = pass(ctx)

    write(ctx, "Notes/Plan.md", "mine")
    FakeVault.put(ctx.vault, "Notes/Plan.md", "theirs")

    {state, report} = pass(ctx, state)

    copy = "Notes/Plan (conflict 2026-10-12 testhost).md"
    assert [%{path: "Notes/Plan.md", copy: ^copy}] = report.conflicts
    assert read(ctx, "Notes/Plan.md") == "theirs"
    assert read(ctx, copy) == "mine"
    # The copy is a page too, so nothing lives only on this machine.
    assert %{content: "mine"} = FakeVault.by_path(ctx.vault, copy)
    assert FakeVault.pages(ctx.vault)[id].content == "theirs"
    assert state["conflicts"] == [copy]

    {state, report} = pass(ctx, state)
    assert quiet?(report)

    # Resolved by deleting the copy: archived, and no longer a conflict.
    File.rm!(Path.join(ctx.root, copy))
    {state, report} = pass(ctx, state)
    assert [%{path: ^copy}] = report.archived
    assert state["conflicts"] == []
  end

  test "the same edit made on both sides is no conflict", ctx do
    FakeVault.put(ctx.vault, "Note.md", "one")
    {state, _} = pass(ctx)

    write(ctx, "Note.md", "same")
    FakeVault.put(ctx.vault, "Note.md", "same")

    {state, report} = pass(ctx, state)
    assert report.conflicts == []
    assert state["entries"]["Note.md"]["hash"] == FakeVault.hash("same")
  end

  test "a two-sided conflict on a file new to both, as after copying a vault in", ctx do
    FakeVault.put(ctx.vault, "Same.md", "identical")
    FakeVault.put(ctx.vault, "Differs.md", "server")
    write(ctx, "Same.md", "identical")
    write(ctx, "Differs.md", "local")

    {_state, report} = pass(ctx)

    # The identical one is adopted, not duplicated (R9.4).
    assert map_size(FakeVault.pages(ctx.vault)) == 3

    assert [%{path: "Differs.md", copy: "Differs (conflict 2026-10-12 testhost).md"}] =
             report.conflicts

    assert read(ctx, "Differs.md") == "server"
  end

  test "a local delete archives the page; a server archive removes the file", ctx do
    gone_here = FakeVault.put(ctx.vault, "Here.md", "h")
    gone_there = FakeVault.put(ctx.vault, "There.md", "t")
    {state, _} = pass(ctx)

    File.rm!(Path.join(ctx.root, "Here.md"))
    FakeVault.archive(ctx.vault, gone_there)

    {state, report} = pass(ctx, state)

    assert [%{path: "Here.md"}] = report.archived
    assert [%{path: "There.md"}] = report.removed
    refute Map.has_key?(FakeVault.pages(ctx.vault), gone_here)
    refute exists?(ctx, "There.md")
    assert state["entries"] == %{}
  end

  test "a file edited here whose page was archived there goes up again as a new page", ctx do
    id = FakeVault.put(ctx.vault, "Keep.md", "old")
    {state, _} = pass(ctx)

    write(ctx, "Keep.md", "edited")
    FakeVault.archive(ctx.vault, id)

    {_state, report} = pass(ctx, state)

    assert [%{path: "Keep.md", id: new_id}] = report.sent
    assert new_id != id
    assert read(ctx, "Keep.md") == "edited"
  end

  test "a file deleted here but changed there comes back", ctx do
    FakeVault.put(ctx.vault, "Note.md", "one")
    {state, _} = pass(ctx)

    File.rm!(Path.join(ctx.root, "Note.md"))
    FakeVault.put(ctx.vault, "Note.md", "two")

    {_state, report} = pass(ctx, state)
    assert report.archived == []
    assert read(ctx, "Note.md") == "two"
  end

  test "a rename or a move here is the same page, renamed there", ctx do
    id = FakeVault.put(ctx.vault, "Old.md", "body")
    {state, _} = pass(ctx)

    File.mkdir_p!(Path.join(ctx.root, "Archive"))
    File.rename!(Path.join(ctx.root, "Old.md"), Path.join(ctx.root, "Archive/New.md"))

    {state, report} = pass(ctx, state)

    assert [%{path: "Archive/New.md", id: ^id}] = report.sent
    assert FakeVault.pages(ctx.vault)[id].path == "Archive/New.md"
    assert map_size(FakeVault.pages(ctx.vault)) == 1
    assert Map.keys(state["entries"]) == ["Archive/New.md"]
  end

  test "a rename there moves the file here, and an emptied folder goes", ctx do
    id = FakeVault.put(ctx.vault, "Inbox/Note.md", "body")
    {state, _} = pass(ctx)

    FakeVault.move(ctx.vault, id, "Done/Note.md")
    {_state, report} = pass(ctx, state)

    assert [%{from: "Inbox/Note.md", path: "Done/Note.md"}] = report.moved
    assert files(ctx) == ["Done/Note.md"]
    refute File.dir?(Path.join(ctx.root, "Inbox"))
  end

  test "what the server writes back after a write replaces the local file", ctx do
    vault =
      FakeVault.start(
        normalise: fn path, content ->
          "---\ntitle: #{Path.basename(path, ".md")}\n---\n" <> content
        end
      )

    ctx = %{ctx | vault: vault}
    write(ctx, "Note.md", "body")

    {state, _} = pass(ctx)

    assert read(ctx, "Note.md") == "---\ntitle: Note\n---\nbody"
    {_state, report} = pass(ctx, state)
    assert quiet?(report)
  end

  test "a write the server refuses is reported and tried again next time", ctx do
    write(ctx, "Note.md", "body")
    FakeVault.fail_next(ctx.vault, "nothing in the vault is mapped at / (HTTP 422)")

    {state, report} = pass(ctx)
    assert [%{path: "Note.md", error: msg}] = report.errors
    assert msg =~ "mapped"
    assert state["errors"] == [%{"path" => "Note.md", "error" => msg}]
    assert FakeVault.pages(ctx.vault) == %{}

    {state, report} = pass(ctx, state)
    assert [%{path: "Note.md"}] = report.sent
    assert state["errors"] == []
  end

  test "dot folders, Obsidian's own files and editors' temp files are never sent", ctx do
    write(ctx, ".obsidian/workspace.md", "x")
    write(ctx, ".trash/Old.md", "x")
    write(ctx, "Note.md~", "x")
    write(ctx, ".Note.md.swp", "x")
    write(ctx, "Note.md.tmp", "x")
    write(ctx, "Real.md", "x")

    {_state, report} = pass(ctx)

    assert [%{path: "Real.md"}] = report.sent
    assert map_size(FakeVault.pages(ctx.vault)) == 1
  end

  test "a file written here while a download was due is moved aside, not overwritten", ctx do
    # The server has a new page at a path where an untracked local file of
    # different content appears: kept as a conflict copy, never clobbered.
    FakeVault.put(ctx.vault, "Clash.md", "server")
    write(ctx, "clash.md", "local")

    {_state, report} = pass(ctx)

    assert [%{copy: copy}] = report.conflicts
    assert read(ctx, copy) == "local"
  end

  test "conflict copies are numbered when the name is taken", ctx do
    write(ctx, "Plan (conflict 2026-10-12 testhost).md", "earlier")

    acc = %{root: ctx.root, host: "testhost", today: ~D[2026-10-12]}
    assert Engine.conflict_name(acc, "Plan.md") == "Plan (conflict 2026-10-12 testhost) 2.md"
    assert Engine.conflict_name(acc, "A/B.md") == "A/B (conflict 2026-10-12 testhost).md"
    # A page's own index is named for the page.
    assert Engine.conflict_name(acc, "Deploys/index.md") ==
             "Deploys/Deploys (conflict 2026-10-12 testhost).md"
  end

  test "a server that can't be listed is an error, not an empty vault", ctx do
    defmodule Down do
      def list(_), do: {:error, "could not reach the server"}
    end

    write(ctx, "Note.md", "x")
    assert {:error, "could not reach the server"} = Engine.run(ctx.root, ctx.state, {Down, nil})
    assert exists?(ctx, "Note.md")
  end

  describe "files that are not notes (R2.9)" do
    test "an image goes up as a file and comes down on another mirror, bytes intact", ctx do
      bytes = :crypto.strong_rand_bytes(3000)
      write(ctx, "Images/photo.png", bytes)

      {state, report} = pass(ctx)

      assert [%{path: "Images/photo.png"}] = report.sent
      assert %{bytes: ^bytes} = FakeVault.file_by_path(ctx.vault, "Images/photo.png")
      assert state["entries"]["Images/photo.png"]["kind"] == "file"
      assert FakeVault.pages(ctx.vault) == %{}

      other = Path.join(ctx.root, "../other-#{System.unique_integer([:positive])}")
      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(other) end)
      {_state, report} = pass(%{ctx | root: other})
      assert [%{path: "Images/photo.png"}] = report.received
      assert File.read!(Path.join(other, "Images/photo.png")) == bytes
    end

    test "a renamed file is moved on the server without sending its bytes again", ctx do
      id = FakeVault.put_file(ctx.vault, "a.pdf", "pdf")
      {state, _} = pass(ctx)

      File.rename!(Path.join(ctx.root, "a.pdf"), Path.join(ctx.root, "b.pdf"))
      {_state, report} = pass(ctx, state)

      assert [%{path: "b.pdf", id: ^id}] = report.sent
      assert {:move_file, id, "b.pdf"} in FakeVault.calls(ctx.vault)
      refute Enum.any?(FakeVault.calls(ctx.vault), &match?({:write_file, _, _}, &1))
    end

    test "edits, deletes and conflicts go by the same rules as notes", ctx do
      edited = FakeVault.put_file(ctx.vault, "edit.png", "v1")
      gone = FakeVault.put_file(ctx.vault, "gone.png", "g")
      both = FakeVault.put_file(ctx.vault, "both.png", "base")
      {state, _} = pass(ctx)

      write(ctx, "edit.png", "v2")
      File.rm!(Path.join(ctx.root, "gone.png"))
      write(ctx, "both.png", "mine")
      FakeVault.put_file(ctx.vault, "both.png", "theirs")

      {state, report} = pass(ctx, state)

      assert FakeVault.files(ctx.vault)[edited].bytes == "v2"
      refute Map.has_key?(FakeVault.files(ctx.vault), gone)
      assert [%{path: "gone.png"}] = report.archived

      copy = "both (conflict 2026-10-12 testhost).png"
      assert [%{path: "both.png", copy: ^copy}] = report.conflicts
      assert read(ctx, "both.png") == "theirs"
      assert read(ctx, copy) =~ "mine"
      assert FakeVault.files(ctx.vault)[both].bytes == "theirs"
      assert %{bytes: "mine"} = FakeVault.file_by_path(ctx.vault, copy)

      FakeVault.archive_file_server(ctx.vault, edited)
      {_state, report} = pass(ctx, state)
      assert [%{path: "edit.png"}] = report.removed
      refute exists?(ctx, "edit.png")
    end

    test "a page and a file with the same id are different things", ctx do
      # On the server pages and files are numbered apart; here, too, a
      # {kind, id} is the identity, never the id alone.
      FakeVault.put(ctx.vault, "Note.md", "n")
      {state, _} = pass(ctx)
      [{"Note.md", %{"id" => id}}] = Map.to_list(state["entries"])

      state =
        put_in(state["entries"]["x.png"], %{
          "id" => id,
          "kind" => "file",
          "hash" => FakeVault.hash("p")
        })

      write(ctx, "x.png", "p")

      {_state, report} = pass(ctx, state)
      # The file's id isn't on the server, so it is removed as archived
      # there, and the page with that id is untouched.
      assert [%{path: "x.png"}] = report.removed
      assert read(ctx, "Note.md") == "n"
    end
  end

  describe "a folder `vault import` sent up (R9.4)" do
    # The server writes a title key into every note, as it may after an
    # import, so the file and the page never have the same hash.
    setup ctx do
      vault =
        FakeVault.start(normalise: fn _path, content -> "---\ntitle: T\n---\n" <> content end)

      %{ctx | vault: vault}
    end

    @vault %{"id" => 1, "name" => "Brain", "mappings" => [%{"path" => "/"}]}

    defp import!(ctx) do
      record = Import.record_for(nil, "http://test", @vault)
      {:ok, listing} = FakeVault.list(ctx.vault)
      plan = Import.plan(ctx.root, @vault, listing, record)
      {record, %{errors: []}} = Import.run(ctx.root, plan, {FakeVault, ctx.vault}, record)
      record["entries"]
    end

    defp adopt(ctx, imported) do
      {:ok, state, report} =
        Engine.run(ctx.root, ctx.state, {FakeVault, ctx.vault},
          host: "testhost",
          today: ~D[2026-10-12],
          imported: imported
        )

      {state, report}
    end

    defp writes(ctx),
      do:
        Enum.filter(
          FakeVault.calls(ctx.vault),
          &match?({w, _, _} when w in [:write, :write_file], &1)
        )

    test "untouched on both sides: adopted, the server's version comes down, nothing new", ctx do
      write(ctx, "Note.md", "body")
      write(ctx, "Sub/Other.md", "other")
      write(ctx, "img/cat.png", "png")
      imported = import!(ctx)
      before = length(writes(ctx))

      {state, report} = adopt(ctx, imported)

      assert length(writes(ctx)) == before
      assert report.conflicts == [] and report.sent == []
      assert map_size(FakeVault.pages(ctx.vault)) == 2
      assert map_size(FakeVault.files(ctx.vault)) == 1
      assert read(ctx, "Note.md") == "---\ntitle: T\n---\nbody"
      assert files(ctx) == ["Note.md", "Sub/Other.md", "img/cat.png"]
      assert state["entries"]["Note.md"]["id"] == imported["Note.md"]["id"]

      {_state, report} = pass(ctx, state)
      assert quiet?(report)
    end

    test "without the record, the same folder would be a conflict on every note", ctx do
      write(ctx, "Note.md", "body")
      import!(ctx)

      {_state, report} = adopt(ctx, nil)

      assert [%{path: "Note.md"}] = report.conflicts
    end

    test "edited here since the import: the edit goes up to the same page", ctx do
      write(ctx, "Note.md", "body")
      imported = import!(ctx)
      write(ctx, "Note.md", "edited")

      {state, report} = adopt(ctx, imported)

      assert report.conflicts == []
      assert [%{path: "Note.md"}] = report.sent
      assert map_size(FakeVault.pages(ctx.vault)) == 1
      assert FakeVault.by_path(ctx.vault, "Note.md").content == "---\ntitle: T\n---\nedited"
      {_state, report} = pass(ctx, state)
      assert quiet?(report)
    end

    test "edited there since the import: the server's edit comes down", ctx do
      write(ctx, "Note.md", "body")
      imported = import!(ctx)
      FakeVault.put(ctx.vault, "Note.md", "theirs")

      {_state, report} = adopt(ctx, imported)

      assert report.conflicts == [] and report.sent == []
      assert read(ctx, "Note.md") == "theirs"
    end

    test "edited on both sides: a conflict, as for any page, and nothing lost", ctx do
      write(ctx, "Note.md", "body")
      imported = import!(ctx)
      FakeVault.put(ctx.vault, "Note.md", "theirs")
      write(ctx, "Note.md", "mine")

      {_state, report} = adopt(ctx, imported)

      assert [%{path: "Note.md", copy: copy}] = report.conflicts
      assert read(ctx, "Note.md") == "theirs"
      assert read(ctx, copy) =~ "mine"
    end

    test "renamed on the server since: the file follows, no second page", ctx do
      write(ctx, "Note.md", "body")
      imported = import!(ctx)
      FakeVault.move(ctx.vault, imported["Note.md"]["id"], "Renamed.md")

      {_state, _report} = adopt(ctx, imported)

      assert files(ctx) == ["Renamed.md"]
      assert map_size(FakeVault.pages(ctx.vault)) == 1
    end

    test "a file deleted here since is not archived there: it comes back down", ctx do
      write(ctx, "Note.md", "body")
      imported = import!(ctx)
      File.rm!(Path.join(ctx.root, "Note.md"))

      {_state, report} = adopt(ctx, imported)

      assert report.archived == []
      assert map_size(FakeVault.pages(ctx.vault)) == 1
      assert exists?(ctx, "Note.md")
    end

    test "a page archived there since does not take the file with it", ctx do
      write(ctx, "Note.md", "body")
      imported = import!(ctx)
      FakeVault.archive(ctx.vault, imported["Note.md"]["id"])

      {_state, report} = adopt(ctx, imported)

      assert report.removed == []
      assert read(ctx, "Note.md") =~ "body"
    end

    test "a path the state already knows is not adopted over", ctx do
      write(ctx, "Note.md", "body")
      imported = import!(ctx)
      {state, _} = adopt(ctx, imported)
      write(ctx, "Note.md", "later")

      {:ok, _state, report} =
        Engine.run(ctx.root, state, {FakeVault, ctx.vault}, imported: imported)

      assert [%{path: "Note.md"}] = report.sent
      assert report.conflicts == []
    end
  end

  describe "folders" do
    defp dir?(ctx, path), do: File.dir?(Path.join(ctx.root, path))

    test "a folder deleted on the server goes from here, once its pages have moved out", ctx do
      FakeVault.put(ctx.vault, "Journal/Acme/Call.md", "call")
      {state, _} = pass(ctx)
      assert state["folders"] == ["Journal", "Journal/Acme"]

      FakeVault.delete_folder(ctx.vault, "Journal")
      {state, report} = pass(ctx, state)

      assert files(ctx) == ["Call.md"]
      refute dir?(ctx, "Journal")
      assert %{path: "Journal/", folder: true} in report.removed
      assert state["folders"] == []

      {_state, report} = pass(ctx, state)
      assert quiet?(report)
    end

    test "an empty folder made on the server is made here, and taken away with it", ctx do
      FakeVault.put(ctx.vault, "Note.md", "one")
      {state, _} = pass(ctx)

      FakeVault.add_folder(ctx.vault, "Design/Old")
      {state, report} = pass(ctx, state)
      assert dir?(ctx, "Design/Old")
      assert report.removed == []

      FakeVault.delete_folder(ctx.vault, "Design")
      {state, report} = pass(ctx, state)

      refute dir?(ctx, "Design")
      assert Enum.map(report.removed, & &1.path) == ["Design/Old/", "Design/"]
      assert state["folders"] == []
    end

    test "a folder emptied here before the server deleted it still goes", ctx do
      FakeVault.put(ctx.vault, "Journal/Call.md", "call")
      {state, _} = pass(ctx)

      File.rm!(Path.join(ctx.root, "Journal/Call.md"))
      {state, _} = pass(ctx, state)
      # The page is archived, but its folder is still on the server, and here.
      FakeVault.add_folder(ctx.vault, "Journal")
      {state, _} = pass(ctx, state)
      assert dir?(ctx, "Journal")

      FakeVault.delete_folder(ctx.vault, "Journal")
      {_state, report} = pass(ctx, state)
      refute dir?(ctx, "Journal")
      assert [%{path: "Journal/"}] = report.removed
    end

    test "anything left in a deleted folder keeps it, and nothing in it is lost", ctx do
      FakeVault.add_folder(ctx.vault, "Journal/Empty")
      {state, _} = pass(ctx)
      write(ctx, "Journal/.private", "not synced")

      FakeVault.delete_folder(ctx.vault, "Journal")
      {state, report} = pass(ctx, state)

      assert read(ctx, "Journal/.private") == "not synced"
      # The empty folder inside it still went.
      refute dir?(ctx, "Journal/Empty")
      assert [%{path: "Journal/Empty/"}] = report.removed
      # Not tried again on the next pass: the server has forgotten it.
      assert state["folders"] == []
      {_state, report} = pass(ctx, state)
      assert quiet?(report)
    end

    test "a file new here in a folder the server deleted goes up, and keeps it", ctx do
      FakeVault.add_folder(ctx.vault, "Journal")
      {state, _} = pass(ctx)

      FakeVault.delete_folder(ctx.vault, "Journal")
      write(ctx, "Journal/New.md", "fresh")
      {_state, report} = pass(ctx, state)

      assert [%{path: "Journal/New.md"}] = report.sent
      assert read(ctx, "Journal/New.md") == "fresh"
      assert report.removed == []
    end

    test "a folder deleted here, but not on the server, is not made again", ctx do
      FakeVault.add_folder(ctx.vault, "Journal")
      {state, _} = pass(ctx)
      File.rmdir!(Path.join(ctx.root, "Journal"))

      {state, report} = pass(ctx, state)
      refute dir?(ctx, "Journal")
      assert quiet?(report)
      assert state["folders"] == ["Journal"]
    end

    test "a link to a folder elsewhere is not followed into", ctx do
      outside = ctx.root <> "-outside"
      File.mkdir_p!(Path.join(outside, "Inner"))
      on_exit(fn -> File.rm_rf!(outside) end)

      FakeVault.add_folder(ctx.vault, "Journal")
      {state, _} = pass(ctx)
      File.ln_s!(outside, Path.join(ctx.root, "Journal/Link"))

      FakeVault.delete_folder(ctx.vault, "Journal")
      {_state, _report} = pass(ctx, state)

      assert File.dir?(Path.join(outside, "Inner"))
    end

    test "a folder .slipdockignore names is neither made nor taken away", ctx do
      write(ctx, ".slipdockignore", "Private/\n")
      FakeVault.add_folder(ctx.vault, "Private")
      {state, _} = pass(ctx)
      refute dir?(ctx, "Private")
      assert state["folders"] == []

      File.mkdir_p!(Path.join(ctx.root, "Private"))
      {state, _} = pass(ctx, Map.put(state, "folders", ["Private"]))
      FakeVault.delete_folder(ctx.vault, "Private")
      {_state, report} = pass(ctx, state)
      assert dir?(ctx, "Private")
      assert report.removed == []
    end

    test "a server that lists no folders leaves folders here alone", ctx do
      vault = FakeVault.start(folders: false)
      ctx = %{ctx | vault: vault}
      FakeVault.put(vault, "Journal/Call.md", "call")
      File.mkdir_p!(Path.join(ctx.root, "Empty"))

      {state, _} = pass(ctx, Map.put(ctx.state, "folders", ["Empty"]))
      assert dir?(ctx, "Empty")
      assert state["folders"] == ["Empty"]
    end

    test "a mirror from before folders were remembered makes none the first time", ctx do
      FakeVault.put(ctx.vault, "Note.md", "one")
      {state, _} = pass(ctx)
      state = Map.delete(state, "folders")
      FakeVault.add_folder(ctx.vault, "Gone here")

      {state, _} = pass(ctx, state)
      refute dir?(ctx, "Gone here")
      assert state["folders"] == ["Gone here"]

      # From then on the server's changes come down as ever.
      FakeVault.add_folder(ctx.vault, "New")
      {_state, _} = pass(ctx, state)
      assert dir?(ctx, "New")
    end
  end

  describe "stubs of what is shared with you (#819)" do
    @stub "[Plan](https://slipdock.example.com/shared/pages/12)\n"

    test "are written where the server lists them, and a second pass leaves them be", ctx do
      FakeVault.put_stub(ctx.vault, "page:12@3", "Inbox/Plan.md", @stub)
      FakeVault.put(ctx.vault, "Note.md", "mine")

      {state, report} = pass(ctx)
      assert read(ctx, "Inbox/Plan.md") == @stub
      assert %{path: "Inbox/Plan.md"} in report.received
      assert state["entries"]["Inbox/Plan.md"]["kind"] == "stub"

      {_state, report} = pass(ctx, state)
      assert quiet?(report)
    end

    test "a local edit is put back, said so, and never sent up", ctx do
      FakeVault.put_stub(ctx.vault, "page:12@3", "Inbox/Plan.md", @stub)
      {state, _} = pass(ctx)

      write(ctx, "Inbox/Plan.md", "my own words")
      {state, report} = pass(ctx, state)

      assert read(ctx, "Inbox/Plan.md") == @stub
      assert [%{path: "Inbox/Plan.md"}] = report.stubs
      assert report.sent == []
      refute Enum.any?(FakeVault.calls(ctx.vault), &match?({:write, _, _}, &1))

      {_state, report} = pass(ctx, state)
      assert quiet?(report)
    end

    test "a stub the server no longer lists goes, edited or not", ctx do
      FakeVault.put_stub(ctx.vault, "page:12@3", "Inbox/Plan.md", @stub)
      FakeVault.put_stub(ctx.vault, "page:13@3", "Inbox/Other.md", @stub)
      {state, _} = pass(ctx)
      write(ctx, "Inbox/Other.md", "edited")

      FakeVault.drop_stub(ctx.vault, "page:12@3")
      FakeVault.drop_stub(ctx.vault, "page:13@3")
      {state, report} = pass(ctx, state)

      refute exists?(ctx, "Inbox/Plan.md")
      refute exists?(ctx, "Inbox/Other.md")
      assert length(report.removed) >= 2
      refute Map.has_key?(state["entries"], "Inbox/Plan.md")
      # Nothing archived on the server for a stub going.
      assert report.archived == []
    end

    test "renamed on the server, the stub moves with it", ctx do
      FakeVault.put_stub(ctx.vault, "page:12@3", "Inbox/Plan.md", @stub)
      {state, _} = pass(ctx)

      FakeVault.put_stub(
        ctx.vault,
        "page:12@3",
        "Inbox/Plan B.md",
        "[Plan B](https://x/shared/pages/12)\n"
      )

      {_state, _report} = pass(ctx, state)

      refute exists?(ctx, "Inbox/Plan.md")
      assert read(ctx, "Inbox/Plan B.md") =~ "Plan B"
    end
  end
end
