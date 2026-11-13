defmodule SlipdockCLI.WikiImportTest do
  @moduledoc """
  `slipdock wiki import` (W-103 R9.1–R9.3): an Obsidian vault brought in
  once, routed to the board whose folder holds it, bytes as they are, nothing on the
  server overwritten, and a dry run that says what would happen and which
  links, embeds and plugin syntax won't resolve.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, FakeVault, WholeWiki}
  alias SlipdockCLI.Sync.{Import, State}

  @boards [
    %{"path" => "/Keystone", "id" => 1, "code" => "kb", "name" => "Keystone"},
    %{"path" => "/Journal Desk", "id" => 2, "code" => "jobs", "name" => "Journal Desk"},
    %{"path" => "/Keystone/Cards/Launch", "id" => 3, "code" => "ln", "name" => "Launch"}
  ]
  @vault %{"id" => 3, "name" => "Brain", "boards" => @boards}

  defp put(dir, path, content) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

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
    Import.plan(ctx.root, vault, listing, Import.record_for(record, "http://test"))
  end

  defp import!(ctx, vault \\ @vault) do
    record = Import.record_for(Import.load_record(ctx.root), "http://test")
    {:ok, listing} = FakeVault.list(ctx.vault)
    plan = Import.plan(ctx.root, vault, listing, record)
    Import.run(ctx.root, plan, {FakeVault, ctx.vault}, record)
  end

  describe "routing" do
    test "a path goes to the deepest board holding it, without regard to case" do
      assert Import.route(@boards, "Keystone/Note.md")["path"] == "/Keystone"
      assert Import.route(@boards, "journal desk/Call.md")["path"] == "/Journal Desk"
      assert Import.route(@boards, "Keystone/Cards/Launch/Plan.md")["id"] == 3
      # A name that only starts like the board's is not in it.
      assert Import.route(@boards, "Keystones/Note.md") == nil
    end

    test "the wiki's root is in no board" do
      assert Import.route(@boards, "Note.md") == nil
    end
  end

  describe "the plan" do
    test "notes and files to create, shallow first, with what is never synced left out", ctx do
      write(ctx, "Keystone/Deep/Er/Note.md", "deep")
      write(ctx, "Keystone/Deep/index.md", "index")
      write(ctx, "Keystone/Deep/Aside.md", "aside")
      write(ctx, "Keystone/Top.md", "top")
      write(ctx, "Keystone/img/cat.png", <<137, 80, 78, 71>>)
      write(ctx, ".obsidian/app.json", "{}")
      write(ctx, ".trash/Old.md", "old")
      write(ctx, "Draft.md.swp", "swap")

      plan = plan(ctx)

      assert Enum.map(plan.create, & &1.path) ==
               [
                 "Keystone/Top.md",
                 "Keystone/Deep/index.md",
                 "Keystone/Deep/Aside.md",
                 "Keystone/img/cat.png",
                 "Keystone/Deep/Er/Note.md"
               ]

      assert Enum.find(plan.create, &(&1.path == "Keystone/img/cat.png")).kind == "file"
      assert Enum.find(plan.create, &(&1.path == "Keystone/Top.md")).kind == "page"
      assert plan.ignored == [".obsidian/", ".trash/", "Draft.md.swp"]
    end

    test "what the server has already is skipped: the same bytes, or listed when different",
         ctx do
      write(ctx, "Keystone/Same.md", "same")
      write(ctx, "Keystone/Other.md", "mine")
      write(ctx, "Keystone/New.md", "new")
      FakeVault.put(ctx.vault, "Keystone/Same.md", "same")
      FakeVault.put(ctx.vault, "Keystone/other.md", "theirs")

      plan = plan(ctx)

      assert Enum.map(plan.create, & &1.path) == ["Keystone/New.md"]
      assert [%{path: "Keystone/Same.md", id: _, hash: _}] = plan.present
      assert [%{path: "Keystone/Other.md"}] = plan.differs
    end

    test "a path in no board's folder is skipped and listed", ctx do
      write(ctx, "Loose.md", "x")
      write(ctx, "Journal Desk/Call.md", "y")

      plan = plan(ctx, @vault)

      assert plan.outside == ["Loose.md"]
      assert [%{path: "Journal Desk/Call.md", board: %{"path" => "/Journal Desk"}}] = plan.create
    end
  end

  describe "links and plugin syntax" do
    test "links resolve by name, path, alias, attachment name or the server; the rest are listed",
         ctx do
      write(ctx, "Keystone/People/Ann.md", "---\naliases: [Annie, \"A. N.\"]\n---\nAnn")
      write(ctx, "Keystone/Projects/X/Plan.md", "plan")
      write(ctx, "Keystone/Drawing.excalidraw.md", "drawing")
      write(ctx, "Keystone/img/cat.png", "png")
      FakeVault.put(ctx.vault, "Keystone/Server Note.md", "on the server")

      write(ctx, "Keystone/Daily.md", """
      [[Ann]] [[Annie|her]] [[A. N.]] [[X/Plan#Goals]] [[Projects/X/Plan.md]]
      [[Server Note]] ![[cat.png]] ![[img/cat.png|200]] ![[Drawing.excalidraw]]
      [[#Heading]] [[#412]] [link](People/Ann.md) [web](https://example.com) [here](#top)
      [rel](../Keystone/Daily.md)
      [[Nobody]] ![[missing.png]] [broken](Gone%20Away.md)
      ```
      [[In Code]]
      ```
      and `[[Inline Code]]`
      """)

      plan = plan(ctx)

      assert Enum.sort(plan.unresolved) ==
               Enum.sort([
                 %{path: "Keystone/Daily.md", link: "[[Nobody]]", embed: false},
                 %{path: "Keystone/Daily.md", link: "![[missing.png]]", embed: true},
                 %{path: "Keystone/Daily.md", link: "[broken](Gone%20Away.md)", embed: false}
               ])
    end

    test "aliases written as a list of lines count too", ctx do
      write(ctx, "Keystone/Ann.md", "---\ntitle: Ann\naliases:\n  - Annie\n  - 'Nan'\n---\nAnn")
      write(ctx, "Keystone/Ref.md", "[[Annie]] [[Nan]]")

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
      write(ctx, "Keystone/Secret.md", meld)
      write(ctx, "Journal Desk/Call.md", front)
      write(ctx, "Keystone/img/cat.png", <<0, 1, 2, 255>>)

      {record, report} = import!(ctx)

      assert Enum.map(report.created, & &1.path) |> Enum.sort() ==
               ["Journal Desk/Call.md", "Keystone/Secret.md", "Keystone/img/cat.png"]

      assert report.errors == []
      assert FakeVault.by_path(ctx.vault, "Keystone/Secret.md").content == meld
      assert FakeVault.by_path(ctx.vault, "Journal Desk/Call.md").content == front
      assert FakeVault.file_by_path(ctx.vault, "Keystone/img/cat.png").bytes == <<0, 1, 2, 255>>

      entry = record["entries"]["Keystone/Secret.md"]
      assert entry["kind"] == "page"
      assert entry["id"] == FakeVault.by_path(ctx.vault, "Keystone/Secret.md").id
      assert entry["sha"] == FakeVault.hash(meld)
      assert entry["hash"] == FakeVault.hash(meld)
      assert record["entries"]["Keystone/img/cat.png"]["kind"] == "file"

      assert Import.load_record(ctx.root) == record
      assert record["url"] == "http://test"
      refute Map.has_key?(record, "vault")
      # The folder's own files are untouched, and it is not made a mirror.
      assert File.read!(Path.join(ctx.root, "Keystone/Secret.md")) == meld
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
      write(ctx, "Keystone/Secrets.md", inline)
      write(ctx, "Keystone/Private/Diary.mdenc", note["file"])

      {record, report} = import!(ctx)

      assert report.errors == []
      assert FakeVault.by_path(ctx.vault, "Keystone/Secrets.md").content == inline

      assert FakeVault.file_by_path(ctx.vault, "Keystone/Private/Diary.mdenc").bytes ==
               note["file"]

      assert record["entries"]["Keystone/Private/Diary.mdenc"]["kind"] == "file"
    end

    test "run again, nothing is sent twice, and only what is new goes up", ctx do
      write(ctx, "Keystone/One.md", "one")
      {_record, _} = import!(ctx)
      write(ctx, "Keystone/Two.md", "two")

      {record, report} = import!(ctx)

      assert Enum.map(report.created, & &1.path) == ["Keystone/Two.md"]
      assert Map.keys(record["entries"]) |> Enum.sort() == ["Keystone/One.md", "Keystone/Two.md"]
      assert length(Enum.filter(FakeVault.calls(ctx.vault), &match?({:write, nil, _}, &1))) == 2
    end

    test "the server's own rewrite is recorded as its hash beside the file's", ctx do
      vault =
        FakeVault.start(normalise: fn _path, content -> "---\ntitle: X\n---\n" <> content end)

      ctx = %{ctx | vault: vault}
      write(ctx, "Keystone/X.md", "body")

      {record, _} = import!(ctx)

      assert record["entries"]["Keystone/X.md"]["sha"] == FakeVault.hash("body")

      assert record["entries"]["Keystone/X.md"]["hash"] ==
               FakeVault.hash("---\ntitle: X\n---\nbody")

      # Re-run: it was imported, so it is not sent again even though the
      # server's bytes differ from the file's.
      {:ok, listing} = FakeVault.list(vault)
      plan = Import.plan(ctx.root, @vault, listing, record)
      assert plan.create == [] and plan.differs == []
      assert [%{path: "Keystone/X.md"}] = plan.imported
    end

    test "a refused write is reported and the rest carry on; a taken path is not overwritten",
         ctx do
      write(ctx, "Keystone/A.md", "a")
      write(ctx, "Keystone/B.md", "b")
      FakeVault.fail_next(ctx.vault, "boom (HTTP 500)")

      {record, report} = import!(ctx)

      assert [%{path: "Keystone/A.md", error: "boom (HTTP 500)"}] = report.errors
      assert Enum.map(report.created, & &1.path) == ["Keystone/B.md"]
      refute Map.has_key?(record["entries"], "Keystone/A.md")
    end

    test "a path taken between the listing and the write is a difference, not an overwrite",
         ctx do
      write(ctx, "Keystone/Race.md", "mine")
      {:ok, listing} = FakeVault.list(ctx.vault)
      record = Import.record_for(nil, "http://test")
      plan = Import.plan(ctx.root, @vault, listing, record)
      FakeVault.put(ctx.vault, "Keystone/Race.md", "theirs")

      {_record, report} = Import.run(ctx.root, plan, {FakeVault, ctx.vault}, record)

      assert [%{path: "Keystone/Race.md"}] = report.differs
      assert FakeVault.by_path(ctx.vault, "Keystone/Race.md").content == "theirs"
    end

    test "a record made against another server is set aside, not reused" do
      old = %{"url" => "http://other", "entries" => %{"Keystone/A.md" => %{}}}
      assert Import.record_for(old, "http://test")["entries"] == %{}
      assert Import.record_for(old, "http://test")["url"] == "http://test"
      assert Import.entries_for(old, "http://test") == nil
      assert Import.entries_for(old, "http://other") == %{"Keystone/A.md" => %{}}
      assert Import.entries_for(nil, "http://test") == nil
    end

    test "a record from when it named a vault is kept, the vault dropped" do
      old = %{
        "url" => "http://test",
        "vault" => %{"id" => 3, "name" => "Brain"},
        "entries" => %{"Keystone/A.md" => %{"id" => 1}}
      }

      kept = Import.record_for(old, "http://test")
      assert kept["entries"] == %{"Keystone/A.md" => %{"id" => 1}}
      refute Map.has_key?(kept, "vault")
      assert Import.entries_for(old, "http://test") == %{"Keystone/A.md" => %{"id" => 1}}
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

    @wiki_json ~s({"wiki":{"boards":[{"id":1,"code":"kb","name":"Keystone","path":"/Keystone"}]},"boards":[]})

    test "a dry run asks, writes nothing, and says what it would do", %{dir: dir} do
      put(dir, "Keystone/Note.md", "[[Nowhere]]\n```dataview\nLIST\n```\n")
      put(dir, "Keystone/cat.png", "png")
      File.mkdir_p!(Path.join(dir, ".obsidian"))
      url = FakeServer.start([{200, @wiki_json}, {200, ~s({"cursor":1,"entries":[]})}])
      System.put_env("SLIPDOCK_URL", url)

      out = capture_io(fn -> WholeWiki.wiki(["import", dir], dry_run: true) end)

      assert_received {:request, "GET", "/api/wiki", _}
      assert_received {:request, "GET", "/api/wiki/sync?stubs=1", _}
      refute_received {:request, _, _, _}
      assert out =~ "into your wiki"
      assert out =~ "dry run"
      assert out =~ "would create: 1 note, 1 file"
      assert out =~ "/Keystone → Keystone wiki"
      assert out =~ "never synced: .obsidian/"
      assert out =~ "unresolved links: 1"
      assert out =~ "Note.md → [[Nowhere]]"
      assert out =~ "Note.md: Dataview query"
      refute File.exists?(Import.record_path(dir))
    end

    test "for real, each file is sent and the next step is named", %{dir: dir} do
      put(dir, "Keystone/Note.md", "hi")
      hash = FakeVault.hash("hi")

      url =
        FakeServer.start([
          {200, @wiki_json},
          {200, ~s({"cursor":1,"entries":[]})},
          {200, ~s({"page":{"kind":"page","id":7,"path":"Keystone/Note.md","hash":"#{hash}"}})}
        ])

      System.put_env("SLIPDOCK_URL", url)

      out = capture_io(fn -> WholeWiki.wiki(["import", dir], []) end)

      assert_received {:request, "PUT", "/api/wiki/sync/pages", body}
      assert body =~ ~s("content":"hi")
      assert out =~ "created: 1 note, 0 files"
      assert out =~ "slipdock sync init #{dir}`"
      refute out =~ "--vault"
      assert Import.load_record(dir)["entries"]["Keystone/Note.md"]["id"] == 7
    end

    test "--vault is ignored, with a note: there is one wiki", %{dir: dir} do
      put(dir, "Keystone/Note.md", "hi")
      url = FakeServer.start([{200, @wiki_json}, {200, ~s({"cursor":1,"entries":[]})}])
      System.put_env("SLIPDOCK_URL", url)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> WholeWiki.wiki(["import", dir], vault: "Brain", dry_run: true) end)
        end)

      assert err =~ "--vault is no longer needed"
      assert_received {:request, "GET", "/api/wiki", _}
    end

    test "a long list is cut short unless --all", %{dir: dir} do
      plan = %{
        create: [],
        present: [],
        imported: [],
        differs: [],
        outside: Enum.map(1..25, &"n#{&1}.md"),
        too_big: [],
        ignored: [],
        unresolved: [],
        plugins: []
      }

      out = capture_io(fn -> WholeWiki.print_import(dir, plan, nil) end)
      assert out =~ "in no board's folder: 25"
      assert out =~ "5 more (--all to see them)"
      refute out =~ "n25.md"

      out = capture_io(fn -> WholeWiki.print_import(dir, plan, nil, all: true) end)
      assert out =~ "n25.md"
    end
  end
end
