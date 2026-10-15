defmodule SlipdockCLI.VaultImportTest do
  @moduledoc """
  `slipdock vault import` (W-103 R9.1–R9.3): an Obsidian vault brought in
  once, routed through the mappings, bytes as they are, nothing on the
  server overwritten, and a dry run that says what would happen and which
  links, embeds and plugin syntax won't resolve.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, FakeVault, Vaults}
  alias SlipdockCLI.Sync.{Import, State}

  @mappings [
    %{"path" => "/", "board" => %{"id" => 1, "code" => "kb", "name" => "Keystone"}},
    %{
      "path" => "/Journal",
      "board" => %{"id" => 2, "code" => "jobs", "name" => "Journal Desk"},
      "folder" => %{"id" => 9, "path" => "Notes"}
    }
  ]
  @vault %{"id" => 3, "name" => "Brain", "mappings" => @mappings}

  setup do
    root = Path.join(System.tmp_dir!(), "slipdock-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, vault: FakeVault.start()}
  end

  defp write(ctx, path, content) do
    full = Path.join(ctx.root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp plan(ctx, vault \\ @vault, record \\ nil) do
    {:ok, listing} = FakeVault.list(ctx.vault)
    Import.plan(ctx.root, vault, listing, Import.record_for(record, "http://test", vault))
  end

  defp import!(ctx, vault \\ @vault) do
    record = Import.record_for(Import.load_record(ctx.root), "http://test", vault)
    {:ok, listing} = FakeVault.list(ctx.vault)
    plan = Import.plan(ctx.root, vault, listing, record)
    Import.run(ctx.root, plan, {FakeVault, ctx.vault}, record)
  end

  describe "routing" do
    test "the longest mapped prefix wins, without regard to case" do
      assert Import.route(@mappings, "Note.md")["path"] == "/"
      assert Import.route(@mappings, "Journal/Acme/Call.md")["path"] == "/Journal"
      assert Import.route(@mappings, "journal/Call.md")["path"] == "/Journal"
      # A name that only starts like the mapping is not under it.
      assert Import.route(@mappings, "Journalsearch.md")["path"] == "/"
    end

    test "a path no mapping covers routes nowhere" do
      only_jobs = [Enum.at(@mappings, 1)]
      assert Import.route(only_jobs, "Note.md") == nil
      assert Import.route(only_jobs, "Journal/Call.md")["path"] == "/Journal"
    end
  end

  describe "the plan" do
    test "notes and files to create, shallow first, with what is never synced left out", ctx do
      write(ctx, "Deep/Er/Note.md", "deep")
      write(ctx, "Deep/index.md", "index")
      write(ctx, "Deep/Aside.md", "aside")
      write(ctx, "Top.md", "top")
      write(ctx, "img/cat.png", <<137, 80, 78, 71>>)
      write(ctx, ".obsidian/app.json", "{}")
      write(ctx, ".trash/Old.md", "old")
      write(ctx, "Draft.md.swp", "swap")

      plan = plan(ctx)

      assert Enum.map(plan.create, & &1.path) ==
               ["Top.md", "Deep/index.md", "Deep/Aside.md", "img/cat.png", "Deep/Er/Note.md"]

      assert Enum.find(plan.create, &(&1.path == "img/cat.png")).kind == "file"
      assert Enum.find(plan.create, &(&1.path == "Top.md")).kind == "page"
      assert plan.ignored == [".obsidian/", ".trash/", "Draft.md.swp"]
    end

    test "what the server has already is skipped: the same bytes, or listed when different",
         ctx do
      write(ctx, "Same.md", "same")
      write(ctx, "Other.md", "mine")
      write(ctx, "New.md", "new")
      FakeVault.put(ctx.vault, "Same.md", "same")
      FakeVault.put(ctx.vault, "other.md", "theirs")

      plan = plan(ctx)

      assert Enum.map(plan.create, & &1.path) == ["New.md"]
      assert [%{path: "Same.md", id: _, hash: _}] = plan.present
      assert [%{path: "Other.md"}] = plan.differs
    end

    test "a path no mapping covers is skipped and listed", ctx do
      write(ctx, "Loose.md", "x")
      write(ctx, "Journal/Call.md", "y")

      plan = plan(ctx, %{@vault | "mappings" => [Enum.at(@mappings, 1)]})

      assert plan.unmapped == ["Loose.md"]
      assert [%{path: "Journal/Call.md", mapping: %{"path" => "/Journal"}}] = plan.create
    end
  end

  describe "links and plugin syntax" do
    test "links resolve by name, path, alias, attachment name or the server; the rest are listed",
         ctx do
      write(ctx, "People/Ann.md", "---\naliases: [Annie, \"A. N.\"]\n---\nAnn")
      write(ctx, "Projects/X/Plan.md", "plan")
      write(ctx, "Drawing.excalidraw.md", "drawing")
      write(ctx, "img/cat.png", "png")
      FakeVault.put(ctx.vault, "Server Note.md", "on the server")

      write(ctx, "Daily.md", """
      [[Ann]] [[Annie|her]] [[A. N.]] [[X/Plan#Goals]] [[Projects/X/Plan.md]]
      [[Server Note]] ![[cat.png]] ![[img/cat.png|200]] ![[Drawing.excalidraw]]
      [[#Heading]] [[#412]] [link](People/Ann.md) [web](https://example.com) [here](#top)
      [rel](../Daily.md)
      [[Nobody]] ![[missing.png]] [broken](Gone%20Away.md)
      ```
      [[In Code]]
      ```
      and `[[Inline Code]]`
      """)

      plan = plan(ctx)

      assert Enum.sort(plan.unresolved) ==
               Enum.sort([
                 %{path: "Daily.md", link: "[[Nobody]]", embed: false},
                 %{path: "Daily.md", link: "![[missing.png]]", embed: true},
                 %{path: "Daily.md", link: "[broken](Gone%20Away.md)", embed: false}
               ])
    end

    test "aliases written as a list of lines count too", ctx do
      write(ctx, "Ann.md", "---\ntitle: Ann\naliases:\n  - Annie\n  - 'Nan'\n---\nAnn")
      write(ctx, "Ref.md", "[[Annie]] [[Nan]]")

      assert plan(ctx).unresolved == []
    end

    test "plugin-only syntax and canvases are listed, per note" do
      text = """
      ---
      kanban-plugin: basic
      ---
      ```dataview
      LIST
      ```
      ```tasks
      not done
      ```
      Due `= this.due` and <% tp.date.now() %>
      ```elixir
      fine
      ```
      """

      assert Import.plugin_syntax(text) == [
               "Dataview query",
               "Tasks query",
               "inline Dataview expression",
               "Templater command",
               "Kanban plugin board"
             ]

      assert Import.plugin_syntax("Plain prose with `code`.") == []
    end

    test "a canvas file is listed as not drawn", ctx do
      write(ctx, "Board.canvas", "{}")
      assert [%{path: "Board.canvas", what: "Canvas" <> _}] = plan(ctx).plugins
    end
  end

  describe "running it" do
    test "notes go up byte for byte and files as files; the record says what each became", ctx do
      meld = "Secret: %%🔐β ZXhhbXBsZQ== 🔐%%\n"
      front = "---\n# a comment\ntags: [a, b]\nzeta: 1\nalpha: \"two\"\n---\nBody\n"
      write(ctx, "Secret.md", meld)
      write(ctx, "Journal/Call.md", front)
      write(ctx, "img/cat.png", <<0, 1, 2, 255>>)

      {record, report} = import!(ctx)

      assert Enum.map(report.created, & &1.path) |> Enum.sort() ==
               ["Journal/Call.md", "Secret.md", "img/cat.png"]

      assert report.errors == []
      assert FakeVault.by_path(ctx.vault, "Secret.md").content == meld
      assert FakeVault.by_path(ctx.vault, "Journal/Call.md").content == front
      assert FakeVault.file_by_path(ctx.vault, "img/cat.png").bytes == <<0, 1, 2, 255>>

      entry = record["entries"]["Secret.md"]
      assert entry["kind"] == "page"
      assert entry["id"] == FakeVault.by_path(ctx.vault, "Secret.md").id
      assert entry["sha"] == FakeVault.hash(meld)
      assert entry["hash"] == FakeVault.hash(meld)
      assert record["entries"]["img/cat.png"]["kind"] == "file"

      assert Import.load_record(ctx.root) == record
      assert record["vault"] == %{"id" => 3, "name" => "Brain"}
      # The folder's own files are untouched, and it is not made a mirror.
      assert File.read!(Path.join(ctx.root, "Secret.md")) == meld
      refute File.exists?(State.path(ctx.root))
    end

    test "Meld's own ciphertext, inline in every version and as a whole .mdenc note, goes up untouched",
         ctx do
      vectors =
        "../../test/support/fixtures/meld_vectors.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> :json.decode()

      inline = Enum.map_join(vectors["inline"], "\r\n", & &1["text"]) <> "\n"
      [note | _] = vectors["notes"]
      write(ctx, "Secrets.md", inline)
      write(ctx, "Private/Diary.mdenc", note["file"])

      {record, report} = import!(ctx)

      assert report.errors == []
      assert FakeVault.by_path(ctx.vault, "Secrets.md").content == inline
      assert FakeVault.file_by_path(ctx.vault, "Private/Diary.mdenc").bytes == note["file"]
      assert record["entries"]["Private/Diary.mdenc"]["kind"] == "file"
    end

    test "run again, nothing is sent twice, and only what is new goes up", ctx do
      write(ctx, "One.md", "one")
      {_record, _} = import!(ctx)
      write(ctx, "Two.md", "two")

      {record, report} = import!(ctx)

      assert Enum.map(report.created, & &1.path) == ["Two.md"]
      assert Map.keys(record["entries"]) |> Enum.sort() == ["One.md", "Two.md"]
      assert length(Enum.filter(FakeVault.calls(ctx.vault), &match?({:write, nil, _}, &1))) == 2
    end

    test "the server's own rewrite is recorded as its hash beside the file's", ctx do
      vault =
        FakeVault.start(normalise: fn _path, content -> "---\ntitle: X\n---\n" <> content end)

      ctx = %{ctx | vault: vault}
      write(ctx, "X.md", "body")

      {record, _} = import!(ctx)

      assert record["entries"]["X.md"]["sha"] == FakeVault.hash("body")
      assert record["entries"]["X.md"]["hash"] == FakeVault.hash("---\ntitle: X\n---\nbody")
      # Re-run: it was imported, so it is not sent again even though the
      # server's bytes differ from the file's.
      {:ok, listing} = FakeVault.list(vault)
      plan = Import.plan(ctx.root, @vault, listing, record)
      assert plan.create == [] and plan.differs == []
      assert [%{path: "X.md"}] = plan.imported
    end

    test "a refused write is reported and the rest carry on; a taken path is not overwritten",
         ctx do
      write(ctx, "A.md", "a")
      write(ctx, "B.md", "b")
      FakeVault.fail_next(ctx.vault, "boom (HTTP 500)")

      {record, report} = import!(ctx)

      assert [%{path: "A.md", error: "boom (HTTP 500)"}] = report.errors
      assert Enum.map(report.created, & &1.path) == ["B.md"]
      refute Map.has_key?(record["entries"], "A.md")
    end

    test "a path taken between the listing and the write is a difference, not an overwrite",
         ctx do
      write(ctx, "Race.md", "mine")
      {:ok, listing} = FakeVault.list(ctx.vault)
      record = Import.record_for(nil, "http://test", @vault)
      plan = Import.plan(ctx.root, @vault, listing, record)
      FakeVault.put(ctx.vault, "Race.md", "theirs")

      {_record, report} = Import.run(ctx.root, plan, {FakeVault, ctx.vault}, record)

      assert [%{path: "Race.md"}] = report.differs
      assert FakeVault.by_path(ctx.vault, "Race.md").content == "theirs"
    end

    test "a record for another vault is set aside, not reused" do
      old = %{"vault" => %{"id" => 99}, "entries" => %{"A.md" => %{}}}
      assert Import.record_for(old, "http://test", @vault)["entries"] == %{}
      assert Import.record_for(old, "http://test", @vault)["vault"]["id"] == 3
      assert Import.entries_for(old, 3) == nil
      assert Import.entries_for(old, 99) == %{"A.md" => %{}}
      assert Import.entries_for(nil, 3) == nil
    end
  end

  describe "the command" do
    setup ctx do
      saved =
        Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})

      System.put_env("HOME", ctx.root)
      System.put_env("SLIPDOCK_TOKEN", "test-token")
      Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

      on_exit(fn ->
        Enum.each(saved, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      dir = Path.join(ctx.root, "Obsidian")
      File.mkdir_p!(dir)
      %{dir: dir}
    end

    @vault_json ~s({"vault":{"id":3,"name":"Brain","mappings":[{"id":1,"path":"/","board":{"id":1,"code":"kb","name":"Keystone"},"folder":null}]}})

    test "a dry run asks, writes nothing, and says what it would do", %{dir: dir} do
      File.write!(Path.join(dir, "Note.md"), "[[Nowhere]]\n```dataview\nLIST\n```\n")
      File.write!(Path.join(dir, "cat.png"), "png")
      File.mkdir_p!(Path.join(dir, ".obsidian"))
      url = FakeServer.start([{200, @vault_json}, {200, ~s({"cursor":1,"entries":[]})}])
      System.put_env("SLIPDOCK_URL", url)

      out =
        capture_io(fn -> Vaults.run("vault", ["import", dir], vault: "Brain", dry_run: true) end)

      assert_received {:request, "GET", "/api/vaults/Brain", _}
      assert_received {:request, "GET", "/api/vaults/3/sync?stubs=1", _}
      refute_received {:request, _, _, _}
      assert out =~ "dry run"
      assert out =~ "would create: 1 note, 1 file"
      assert out =~ "/ → Keystone wiki"
      assert out =~ "never synced: .obsidian/"
      assert out =~ "unresolved links: 1"
      assert out =~ "Note.md → [[Nowhere]]"
      assert out =~ "Note.md: Dataview query"
      refute File.exists?(Import.record_path(dir))
    end

    test "for real, each file is sent and the next step is named", %{dir: dir} do
      File.write!(Path.join(dir, "Note.md"), "hi")
      hash = FakeVault.hash("hi")

      url =
        FakeServer.start([
          {200, @vault_json},
          {200, ~s({"cursor":1,"entries":[]})},
          {200, ~s({"page":{"kind":"page","id":7,"path":"Note.md","hash":"#{hash}"}})}
        ])

      System.put_env("SLIPDOCK_URL", url)

      out = capture_io(fn -> Vaults.run("vault", ["import", dir], vault: "Brain") end)

      assert_received {:request, "PUT", "/api/vaults/3/sync/pages", body}
      assert body =~ ~s("content":"hi")
      assert out =~ "created: 1 note, 0 files"
      assert out =~ "slipdock sync init"
      assert Import.load_record(dir)["entries"]["Note.md"]["id"] == 7
    end

    test "a long list is cut short unless --all", %{dir: dir} do
      plan = %{
        create: [],
        present: [],
        imported: [],
        differs: [],
        unmapped: Enum.map(1..25, &"n#{&1}.md"),
        too_big: [],
        ignored: [],
        unresolved: [],
        plugins: []
      }

      out = capture_io(fn -> Vaults.print_import(dir, @vault, plan, nil) end)
      assert out =~ "no mapping covers them: 25"
      assert out =~ "5 more (--all to see them)"
      refute out =~ "n25.md"

      out = capture_io(fn -> Vaults.print_import(dir, @vault, plan, nil, all: true) end)
      assert out =~ "n25.md"
    end
  end
end
