defmodule Slipdock.WikiTreeTest do
  @moduledoc """
  The tree a browser draws, one container at a time (W-103 R11.1): what each
  container holds, in what order, what each row says, and that no body is
  ever read for it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.Repo
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Folders, Tree, WikiFile}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    %{user: user, board: board}
  end

  defp page(board, user, title, opts \\ []) do
    attrs =
      %{"title" => title, "body" => opts[:body] || "…"}
      |> maybe(opts[:parent], &Map.put(&1, "parent_id", &2.id))
      |> maybe(opts[:status], &Map.put(&1, "status", &2))
      |> maybe(opts[:template], &Map.put(&1, "template", &2))

    {:ok, page} = Wiki.create_page(board, attrs, user: user)

    case opts[:folder] do
      nil -> page
      folder -> elem(Folders.put_page(page, folder), 1)
    end
  end

  defp maybe(map, nil, _fun), do: map
  defp maybe(map, value, fun), do: fun.(map, value)

  defp folder(board, name, parent \\ nil) do
    {:ok, folder} =
      Wiki.create_folder(board, %{"name" => name, "parent_id" => parent && parent.id})

    folder
  end

  defp file(board, name, folder \\ nil) do
    Repo.insert!(%WikiFile{
      board_id: board.id,
      folder_id: folder && folder.id,
      name: name,
      content_type: "image/png",
      size: 1,
      sha256: "x",
      key: "k/#{name}"
    })
  end

  defp titles({:ok, rows}), do: Enum.map(rows, &{&1.kind, &1.title})

  describe "parse_ref/1" do
    test "reads the root, a folder and a page, and refuses anything else" do
      assert Tree.parse_ref("root") == {:ok, :root}
      assert Tree.parse_ref("") == {:ok, :root}
      assert Tree.parse_ref(nil) == {:ok, :root}
      assert Tree.parse_ref("folder:") == {:ok, :root}
      assert Tree.parse_ref("folder:12") == {:ok, {:folder, 12}}
      assert Tree.parse_ref("page:7") == {:ok, {:page, 7}}
      assert Tree.parse_ref("page:x") == :error
      assert Tree.parse_ref("page:0") == :error
      assert Tree.parse_ref("card:7") == :error
      assert Tree.ref_key({:folder, 12}) == "folder:12"
      assert Tree.ref_key(:root) == "root"
    end
  end

  describe "children/3" do
    test "the root holds the top folders first, then unfiled pages by position and title, then files",
         %{board: board, user: user} do
      design = folder(board, "Design")
      _inner = folder(board, "Decisions", design)
      page(board, user, "Filed", folder: design)
      page(board, user, "Zebra")
      page(board, user, "Apple")
      file(board, "logo.png")
      file(board, "deep.png", design)

      assert titles(Tree.children(board, :root)) == [
               {"folder", "Design"},
               {"page", "Apple"},
               {"page", "Zebra"},
               {"file", "logo.png"}
             ]
    end

    test "a folder holds its subfolders, its top pages and its files, with counts",
         %{board: board, user: user} do
      design = folder(board, "Design")
      decisions = folder(board, "Decisions", design)
      _empty = folder(board, "Empty", design)
      top = page(board, user, "Top", folder: design)
      page(board, user, "Under top", folder: design, parent: top)
      page(board, user, "Deep", folder: decisions)
      file(board, "sketch.png", design)

      {:ok, [row]} = Tree.children(board, :root)
      # Two subfolders, one top page, one file — and three pages beneath it.
      assert %{kind: "folder", title: "Design", count: 4, pages: 3} = row

      {:ok, rows} = Tree.children(board, {:folder, design.id})

      assert Enum.map(rows, &{&1.kind, &1.title, &1.count}) == [
               {"folder", "Decisions", 1},
               {"folder", "Empty", 0},
               {"page", "Top", 1},
               {"file", "sketch.png", 0}
             ]

      assert titles(Tree.children(board, {:page, top.id})) == [{"page", "Under top"}]
    end

    test "a child filed in another folder than its parent sits at the top of its own",
         %{board: board, user: user} do
      a = folder(board, "A")
      b = folder(board, "B")
      parent = page(board, user, "Parent", folder: a)
      page(board, user, "Elsewhere", folder: b, parent: parent)

      {:ok, [%{title: "Parent", count: 0}]} = Tree.children(board, {:folder, a.id})
      assert titles(Tree.children(board, {:folder, b.id})) == [{"page", "Elsewhere"}]
      assert Tree.children(board, {:page, parent.id}) == {:ok, []}
    end

    test "a page whose parent is hidden stands at the top instead of vanishing",
         %{board: board, user: user} do
      draft = page(board, user, "Half done", status: "draft")
      page(board, user, "Child of a draft", parent: draft)

      # A writer sees the draft, with its child under it.
      assert titles(Tree.children(board, :root)) == [{"page", "Half done"}]

      # A reader does not, and the child comes up to where they can see it.
      assert titles(Tree.children(board, :root, status: "published")) ==
               [{"page", "Child of a draft"}]
    end

    test "drafts, templates and archived pages follow the options",
         %{board: board, user: user} do
      page(board, user, "Plain")
      page(board, user, "Draft", status: "draft")
      page(board, user, "Template", template: true)
      gone = page(board, user, "Gone")
      {:ok, _} = Wiki.archive_page(gone)

      {:ok, rows} = Tree.children(board, :root)
      assert Enum.map(rows, & &1.title) |> Enum.sort() == ["Draft", "Plain", "Template"]
      assert Enum.find(rows, &(&1.title == "Draft")).draft
      assert Enum.find(rows, &(&1.title == "Template")).template

      assert titles(Tree.children(board, :root, status: "published", template: false)) ==
               [{"page", "Plain"}]

      {:ok, all} = Tree.children(board, :root, archived: :all)
      assert Enum.find(all, &(&1.title == "Gone")).archived
    end

    test "a folder's counts leave out what the options hide", %{board: board, user: user} do
      design = folder(board, "Design")
      page(board, user, "Shown", folder: design)
      page(board, user, "Draft", folder: design, status: "draft")

      {:ok, [%{pages: 2, count: 2}]} = Tree.children(board, :root)
      {:ok, [%{pages: 1, count: 1}]} = Tree.children(board, :root, status: "published")
    end

    test "only lets the named pages through, and files stay out while it does",
         %{board: board, user: user} do
      design = folder(board, "Design")
      keep = page(board, user, "Keep", folder: design)
      page(board, user, "Drop", folder: design)
      page(board, user, "Loose")
      file(board, "logo.png")

      only = MapSet.new([keep.id])
      {:ok, [%{title: "Design", pages: 1, count: 1}]} = Tree.children(board, :root, only: only)
      assert titles(Tree.children(board, {:folder, design.id}, only: only)) == [{"page", "Keep"}]
    end

    test "a row carries the facets a filter or a badge needs, and never a body",
         %{board: board, user: user} do
      p = page(board, user, "Facets", body: String.duplicate("long ", 1000))
      {:ok, _} = Wiki.update_page(p, %{"priority" => "high", "flags" => ["blocked"]}, user: user)

      {:ok, [row]} = Tree.children(board, :root)

      assert %{
               kind: "page",
               title: "Facets",
               code: "W-" <> _,
               priority: "high",
               flags: ["blocked"],
               draft: false,
               archived: false,
               count: 0
             } = row

      refute Map.has_key?(row, :body)
    end

    test "a folder or page from another board is not found", %{board: board, user: user} do
      other = board_fixture(%{"name" => "Other", "code" => "other"}, owner: user)
      theirs = folder(other, "Theirs")
      their_page = page(other, user, "Theirs")

      assert Tree.children(board, {:folder, theirs.id}) == {:error, :not_found}
      assert Tree.children(board, {:page, their_page.id}) == {:error, :not_found}
      assert Tree.children(board, {:folder, 999_999}) == {:error, :not_found}
    end
  end

  describe "path_to/1 and count/2" do
    test "the folders and parent pages leading to a page, outermost first",
         %{board: board, user: user} do
      design = folder(board, "Design")
      decisions = folder(board, "Decisions", design)
      top = page(board, user, "Top", folder: decisions)
      mid = page(board, user, "Mid", folder: decisions, parent: top)
      leaf = page(board, user, "Leaf", folder: decisions, parent: mid)

      assert Tree.path_to(leaf) ==
               [{:folder, design.id}, {:folder, decisions.id}, {:page, top.id}, {:page, mid.id}]

      assert Tree.path_to_folder(decisions) == [{:folder, design.id}, {:folder, decisions.id}]
    end

    test "a parent filed elsewhere is not on the way", %{board: board, user: user} do
      a = folder(board, "A")
      parent = page(board, user, "Parent")
      child = page(board, user, "Child", folder: a, parent: parent)

      assert Tree.path_to(child) == [{:folder, a.id}]
    end

    test "count says how many pages the options show", %{board: board, user: user} do
      page(board, user, "One")
      page(board, user, "Two", status: "draft")

      assert Tree.count(board) == 2
      assert Tree.count(board, status: "published") == 1
    end
  end

  describe "filter/3" do
    setup %{board: board, user: user} do
      specs = folder(board, "Specs")
      drafts = folder(board, "Drafts", specs)
      _contracts = folder(board, "Contracts")
      plan = page(board, user, "Plan", folder: drafts)
      retry = page(board, user, "Retry policy", folder: drafts, parent: plan)
      loose = page(board, user, "Launch notes")
      %{specs: specs, drafts: drafts, plan: plan, retry: retry, loose: loose}
    end

    defp filters(changes), do: Map.merge(Slipdock.Filters.empty(), changes)

    test "a match comes with the folders and pages above it, marked as context", %{
      board: board,
      specs: specs,
      drafts: drafts,
      plan: plan
    } do
      result = Tree.filter(board, filters(%{q: "retry"}))

      assert result.shown == 1
      assert Enum.map(result.nodes["root"], & &1.title) == ["Specs"]
      assert [%{title: "Drafts", count: 1, pages: 2}] = result.nodes["folder:#{specs.id}"]
      assert [%{title: "Plan", context: true, count: 1}] = result.nodes["folder:#{drafts.id}"]
      assert [%{title: "Retry policy"} = hit] = result.nodes["page:#{plan.id}"]
      refute Map.has_key?(hit, :context)
      assert MapSet.member?(result.only, hd(result.nodes["page:#{plan.id}"]).id)
    end

    test "a folder whose name matches brings everything filed beneath it", %{
      board: board,
      specs: specs
    } do
      result = Tree.filter(board, filters(%{q: "spec"}))

      assert result.shown == 2
      assert Enum.map(result.nodes["root"], & &1.title) == ["Specs"]
      assert [%{title: "Drafts"}] = result.nodes["folder:#{specs.id}"]
    end

    test "a folder hit with nothing in it is still shown, and nothing else is", %{board: board} do
      result = Tree.filter(board, filters(%{q: "contract"}))

      assert result.shown == 0
      assert [%{title: "Contracts", count: 0, pages: 0}] = result.nodes["root"]
      assert Map.keys(result.nodes) == ["root"]
    end

    test "the facet filters read each page, and nothing matching leaves no nodes", %{
      board: board,
      user: user,
      loose: loose
    } do
      {:ok, _} = Wiki.update_page(loose, %{"priority" => "high"}, user: user)

      result = Tree.filter(board, filters(%{priority: "high"}))
      assert Map.keys(result.nodes) == ["root"]
      assert [%{title: "Launch notes", priority: "high"}] = result.nodes["root"]

      assert Tree.filter(board, filters(%{priority: "critical"})).nodes == %{}
    end

    test "#tag finds notes tagged so, nested tags included, and board tags by name", %{
      board: board,
      user: user,
      loose: loose,
      plan: plan
    } do
      Repo.update_all(
        from(p in Slipdock.Wiki.Page, where: p.id == ^loose.id),
        set: [note_tags: ["area/ops"]]
      )

      tag = tag_fixture(board, "Urgent")
      {:ok, _} = Wiki.set_tags(plan, [tag])

      assert Tree.filter(board, filters(%{q: "#area"})).shown == 1
      assert Tree.filter(board, filters(%{q: "#area/ops launch"})).shown == 1
      assert Tree.filter(board, filters(%{q: "#area retry"})).shown == 0
      assert %{shown: 1, only: only} = Tree.filter(board, filters(%{q: "#urgent"}))
      assert MapSet.member?(only, plan.id)
      assert Tree.split_query("retry  #Ops/On #x") == {"retry", ["ops/on", "x"]}
      assert Tree.split_query("#") == {"#", []}
    end

    test "contents finds the words inside a page, only when asked", %{board: board, user: user} do
      page(board, user, "Plain title", body: "The rollback takes 100% of the night")

      assert Tree.filter(board, filters(%{q: "rollback"})).shown == 0
      assert Tree.filter(board, filters(%{q: "rollback"}), contents: true).shown == 1
      # Wildcards typed are only characters.
      assert Tree.filter(board, filters(%{q: "100%"}), contents: true).shown == 1
      assert Tree.filter(board, filters(%{q: "1_0"}), contents: true).shown == 0
    end

    test "the visibility options still apply under a filter", %{board: board, user: user} do
      page(board, user, "Launch draft", status: "draft")

      assert board |> Tree.filter(filters(%{q: "launch"})) |> Map.get(:shown) == 2

      assert board
             |> Tree.filter(filters(%{q: "launch"}), status: "published")
             |> Map.get(:shown) == 1
    end
  end

  describe "a big container, a page at a time" do
    setup %{board: board, user: user} do
      inbox = folder(board, "Inbox")

      pages =
        for n <- 1..12,
            do: page(board, user, "Note #{String.pad_leading("#{n}", 2, "0")}", folder: inbox)

      file(board, "last.png", inbox)
      %{inbox: inbox, pages: pages}
    end

    test "limit gives a page of rows and says where the rest starts", %{
      board: board,
      inbox: inbox
    } do
      {:ok, rows} = Tree.children(board, {:folder, inbox.id}, limit: 5)
      assert length(rows) == 6
      assert %{kind: "more", offset: 5} = List.last(rows)
      refute Enum.any?(rows, &(&1.kind == "file"))

      {:ok, rest} = Tree.children(board, {:folder, inbox.id}, limit: 5, offset: 10)
      assert Enum.map(rest, & &1.title) == ["Note 11", "Note 12", "last.png"]
    end

    test "through reaches as far as the page asked for", %{
      board: board,
      inbox: inbox,
      pages: pages
    } do
      deep = Enum.at(pages, 10)
      {:ok, rows} = Tree.children(board, {:folder, inbox.id}, limit: 5, through: deep.id)

      assert Enum.any?(rows, &(&1[:id] == deep.id))
      assert %{kind: "more", offset: 11} = List.last(rows)

      # A page that is not in the container changes nothing.
      {:ok, rows} = Tree.children(board, {:folder, inbox.id}, limit: 5, through: 999_999)
      assert length(rows) == 6
    end
  end

  describe "pages filed in several folders (R12.2)" do
    test "a folder lists the pages also filed in it, marked, once each", %{
      board: board,
      user: user
    } do
      home = folder(board, "Home")
      ideas = folder(board, "Ideas")
      page = page(board, user, "Plan", folder: home)
      {:ok, _} = Slipdock.Wiki.Placements.add(page, ideas, user)

      {:ok, rows} = Tree.children(board, {:folder, ideas.id}, as: user)
      assert [%{title: "Plan", also: true, placed_in: placed_in, id: id}] = rows
      assert placed_in == ideas.id
      assert id == page.id

      # At home it is an ordinary row, and the folder totals count it once.
      {:ok, [%{title: "Plan"} = at_home]} = Tree.children(board, {:folder, home.id}, as: user)
      refute Map.has_key?(at_home, :also)
      {:ok, folders} = Tree.children(board, :root, as: user)
      assert %{pages: 1} = Enum.find(folders, &(&1.title == "Home"))
      assert %{pages: 0, count: 1} = Enum.find(folders, &(&1.title == "Ideas"))
    end

    test "only readers of the page's home board see it, and drafts only its writers", %{
      board: board,
      user: owner
    } do
      ideas = folder(board, "Ideas")
      other = board_fixture(%{"name" => "Other", "code" => "otheralso"}, owner: owner)
      {:ok, vault} = Slipdock.Vaults.create_vault(owner, %{"name" => "V"})
      {:ok, _} = Slipdock.Vaults.add_mapping(vault, owner, %{path: "/", board: board})
      {:ok, _} = Slipdock.Vaults.add_mapping(vault, owner, %{path: "/O", board: other})
      theirs = page(other, owner, "Elsewhere")
      draft = page(board, owner, "Half", status: "draft")
      {:ok, _} = Slipdock.Wiki.Placements.add(theirs, ideas, owner)
      {:ok, _} = Slipdock.Wiki.Placements.add(draft, ideas, owner)

      {:ok, rows} = Tree.children(board, {:folder, ideas.id}, as: owner)
      assert Enum.map(rows, & &1.title) |> Enum.sort() == ["Elsewhere", "Half"]

      reader = user_fixture("also.reader@example.com")
      share_fixture(board, reader, "read")

      {:ok, rows} = Tree.children(board, {:folder, ideas.id}, as: reader, status: "published")
      assert rows == []

      # With nobody named, only the folder's own board's pages.
      {:ok, rows} = Tree.children(board, {:folder, ideas.id})
      assert Enum.map(rows, & &1.title) == ["Half"]
    end
  end

  describe "sorting a folder (R11.9)" do
    setup %{board: board, user: user} do
      inbox = folder(board, "Inbox")
      zeta = folder(board, "Zeta", inbox)
      alpha = folder(board, "alpha", inbox)
      b = page(board, user, "banana", folder: inbox)
      a = page(board, user, "Apple", folder: inbox)
      c = page(board, user, "cherry", folder: inbox)

      stamp = fn page, at ->
        Repo.update_all(from(p in Slipdock.Wiki.Page, where: p.id == ^page.id),
          set: [updated_at: at, inserted_at: at]
        )
      end

      stamp.(a, ~U[2026-01-01 00:00:00Z])
      stamp.(b, ~U[2026-03-01 00:00:00Z])
      stamp.(c, ~U[2026-02-01 00:00:00Z])
      Repo.update_all(from(p in Slipdock.Wiki.Page, where: p.id == ^c.id), set: [position: -1])
      %{inbox: inbox, zeta: zeta, alpha: alpha}
    end

    defp listed(board, inbox) do
      {:ok, rows} = Tree.children(board, {:folder, inbox.id})
      Enum.map(rows, & &1.title)
    end

    test "manual by default, then by name, modified or created, folders first", %{
      board: board,
      inbox: inbox
    } do
      assert listed(board, inbox) == ["Zeta", "alpha", "cherry", "Apple", "banana"]

      {:ok, inbox} = Wiki.set_tree_sort(board, inbox, "name")
      assert listed(board, inbox) == ["alpha", "Zeta", "Apple", "banana", "cherry"]

      {:ok, inbox} = Wiki.set_tree_sort(board, inbox, "modified")
      assert listed(board, inbox) == ["Zeta", "alpha", "banana", "cherry", "Apple"]

      {:ok, inbox} = Wiki.set_tree_sort(board, inbox, "created")
      assert {:ok, [_, _ | _]} = Tree.children(board, {:folder, inbox.id})
      assert %{sort: "created"} = hd(elem(Tree.children(board, :root), 1))
    end

    test "a filter keeps the folder's order", %{board: board, inbox: inbox} do
      {:ok, _} = Wiki.set_tree_sort(board, inbox, "name")
      result = Tree.filter(board, Map.put(Slipdock.Filters.empty(), :q, "a"))
      # Zeta is a hit by its name, as alpha is; then the pages, by name.
      assert Enum.map(result.nodes["folder:#{inbox.id}"], & &1.title) ==
               ["alpha", "Zeta", "Apple", "banana"]
    end

    test "the top of the board has its own, and nonsense is refused", %{
      board: board,
      user: user,
      inbox: inbox
    } do
      page(board, user, "Zed")
      page(board, user, "Ant")
      {:ok, board} = Wiki.set_tree_sort(board, nil, "name")
      assert {:ok, [_inbox, %{title: "Ant"}, %{title: "Zed"}]} = Tree.children(board, :root)

      assert {:error, :unprocessable_entity, _} = Wiki.set_tree_sort(board, nil, "random")
      assert {:error, :unprocessable_entity, _} = Wiki.set_tree_sort(board, inbox, "random")
      other = board_fixture(%{"name" => "O", "code" => "osort"}, owner: user)
      assert {:error, :unprocessable_entity, _} = Wiki.set_tree_sort(other, inbox, "name")
    end
  end

  describe "moving a page among its siblings" do
    test "sibling_ids lists them in order, and a move packs every position", %{
      board: board,
      user: user
    } do
      [a, b, c] = for t <- ["A", "B", "C"], do: page(board, user, t)
      moving = page(board, user, "D")

      assert Wiki.sibling_ids(board.id, nil, moving.id) == [a.id, b.id, c.id]

      {:ok, _} = Wiki.move_page(moving, nil, 1)

      positions =
        Map.new(Repo.all(from(p in Slipdock.Wiki.Page, select: {p.id, p.position})))

      assert Enum.sort_by([a, moving, b, c], &positions[&1.id]) |> Enum.map(& &1.title) ==
               ["A", "D", "B", "C"]

      assert Enum.sort(Map.values(positions)) == [0, 1, 2, 3]
      assert Wiki.sibling_ids(board.id, nil) == [a.id, moving.id, b.id, c.id]
    end
  end

  describe "the helpers a listing uses" do
    test "recent lists the latest changed, as rows", %{board: board, user: user} do
      old = page(board, user, "Old")
      page(board, user, "New")

      Repo.update_all(
        from(p in Slipdock.Wiki.Page, where: p.id == ^old.id),
        set: [updated_at: ~U[2020-01-01 00:00:00Z]]
      )

      assert [%{title: "New", kind: "page"}, %{title: "Old"}] = Tree.recent(board, [], 5)
      assert [%{title: "New"}] = Tree.recent(board, [], 1)
      assert [%{title: "Old"}] = Tree.recent(board, [only: MapSet.new([old.id])], 5)
    end

    test "excerpts read the summary and the start of the body only", %{board: board, user: user} do
      long = page(board, user, "Long", body: String.duplicate("a", 2000))

      {:ok, summed} =
        Wiki.create_page(board, %{"title" => "Summed", "summary" => "In short."}, user: user)

      excerpts = Tree.excerpts([long.id, summed.id])
      assert String.length(excerpts[long.id].body) == 400
      assert excerpts[summed.id].summary == "In short."
      assert Tree.excerpts([]) == %{}
    end

    test "prepare reads the folders and their counts once for several containers", %{
      board: board,
      user: user
    } do
      design = folder(board, "Design")
      page(board, user, "Inside", folder: design)
      opts = Tree.prepare(board, status: "published")

      assert [%{id: id}] = opts[:folders]
      assert id == design.id
      assert opts[:stats].totals[design.id] == 1
      assert {:ok, [%{pages: 1}]} = Tree.children(board, :root, opts)
    end
  end

  describe "a vault's tree" do
    setup %{board: kb, user: user} do
      jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobhunt"}, owner: user)
      proj = board_fixture(%{"name" => "Project X", "code" => "projx"}, owner: user)
      notes = folder(proj, "Notes")
      {:ok, vault} = Slipdock.Vaults.create_vault(user, %{"name" => "Brain"})
      {:ok, _} = Slipdock.Vaults.add_mapping(vault, user, %{path: "/", board: kb})
      {:ok, _} = Slipdock.Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})

      {:ok, _} =
        Slipdock.Vaults.add_mapping(vault, user, %{
          path: "/Projects/X",
          board: proj,
          folder: notes
        })

      page(kb, user, "Home note")
      acme = folder(jobs, "Acme")
      call = page(jobs, user, "Call", folder: acme)
      idea = page(proj, user, "Idea", folder: notes)

      boards = Map.new([kb, jobs, proj], &{&1.id, {&1, []}})

      %{
        vault: vault,
        jobs: jobs,
        proj: proj,
        notes: notes,
        acme: acme,
        call: call,
        idea: idea,
        boards: boards
      }
    end

    test "the root holds the vault's folders, then what is mapped at the root", %{
      vault: vault,
      boards: boards,
      jobs: jobs
    } do
      {:ok, rows} = Tree.vault_children(vault, "vault", boards)

      assert Enum.map(rows, &{&1.kind, &1.title, &1[:key]}) == [
               {"folder", "Jobs", "board:#{jobs.id}"},
               {"dir", "Projects", "dir:Projects"},
               {"page", "Home note", nil}
             ]

      assert %{mount: true, pages: 1, board_id: board_id} = hd(rows)
      assert board_id == jobs.id
    end

    test "a path leading to deeper mappings opens onto them; a mapping onto its board", %{
      vault: vault,
      boards: boards,
      jobs: jobs,
      notes: notes,
      acme: acme
    } do
      assert {:ok, [%{title: "X", key: key, pages: 1}]} =
               Tree.vault_children(vault, "dir:Projects", boards)

      assert key == "folder:#{notes.id}"
      assert {:ok, [%{title: "Idea"}]} = Tree.vault_children(vault, key, boards)
      assert {:ok, [%{title: "Acme"}]} = Tree.vault_children(vault, "board:#{jobs.id}", boards)
      assert {:ok, [%{title: "Call"}]} = Tree.vault_children(vault, "folder:#{acme.id}", boards)
    end

    test "nothing outside the boards given is found", %{
      vault: vault,
      boards: boards,
      jobs: jobs,
      acme: acme,
      user: user
    } do
      stranger = board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere"}, owner: user)
      theirs = folder(stranger, "Theirs")

      assert Tree.vault_children(vault, "folder:#{theirs.id}", boards) == {:error, :not_found}
      assert Tree.vault_children(vault, "dir:Nowhere", boards) == {:error, :not_found}
      assert Tree.vault_children(vault, "board:junk", boards) == {:error, :not_found}

      # A board the reader may not open drops out of the vault's tree.
      without = Map.delete(boards, jobs.id)
      assert Tree.vault_children(vault, "folder:#{acme.id}", without) == {:error, :not_found}
      {:ok, rows} = Tree.vault_children(vault, "vault", without)
      refute Enum.any?(rows, &(&1.title == "Jobs"))
    end

    test "the way to a page runs through the vault's folders to the board's", %{
      vault: vault,
      boards: boards,
      jobs: jobs,
      notes: notes,
      acme: acme,
      call: call,
      idea: idea
    } do
      assert Tree.vault_path_to(vault, call, boards) == ["board:#{jobs.id}", "folder:#{acme.id}"]
      assert Tree.vault_path_to(vault, idea, boards) == ["dir:Projects", "folder:#{notes.id}"]
      assert Tree.vault_path_to(vault, acme, boards) == ["board:#{jobs.id}", "folder:#{acme.id}"]
    end

    test "a filter runs across the vault, keeping only the paths that hold a match", %{
      vault: vault,
      boards: boards,
      jobs: jobs,
      acme: acme,
      notes: notes
    } do
      result = Tree.vault_filter(vault, boards, Map.put(Slipdock.Filters.empty(), :q, "call"))

      assert result.shown == 1
      assert [%{title: "Jobs", key: key, pages: 1}] = result.nodes["vault"]
      assert key == "board:#{jobs.id}"
      assert [%{title: "Acme"}] = result.nodes["board:#{jobs.id}"]
      assert [%{title: "Call"}] = result.nodes["folder:#{acme.id}"]
      refute Map.has_key?(result.nodes, "dir:Projects")
      refute Map.has_key?(result.nodes, "folder:#{notes.id}")

      result = Tree.vault_filter(vault, boards, Map.put(Slipdock.Filters.empty(), :q, "idea"))
      assert [%{title: "Projects", key: "dir:Projects"}] = result.nodes["vault"]
      assert [%{title: "X", pages: 1}] = result.nodes["dir:Projects"]

      assert Tree.vault_filter(vault, boards, Map.put(Slipdock.Filters.empty(), :q, "zzz")).nodes ==
               %{}
    end

    test "mounts sort in among the board's folders, not above them (#758)", %{
      vault: vault,
      boards: boards,
      board: kb,
      jobs: jobs
    } do
      folder(kb, "Archive")
      folder(kb, "Zeta")

      {:ok, rows} = Tree.vault_children(vault, "vault", boards)

      assert Enum.map(rows, &{&1.kind, &1.title}) == [
               {"folder", "Archive"},
               {"folder", "Jobs"},
               {"dir", "Projects"},
               {"folder", "Zeta"},
               {"page", "Home note"}
             ]

      # The board's own top, keyed as its wiki asks for it, is the same.
      {:ok, rows} = Tree.vault_children(vault, "board:#{kb.id}", boards)
      assert Enum.map(rows, & &1.title) == ["Archive", "Jobs", "Projects", "Zeta", "Home note"]
      assert %{mount: true, board_id: id} = Enum.find(rows, &(&1.title == "Jobs"))
      assert id == jobs.id
    end

    test "mounts come with the first page of rows, as folders do", %{
      vault: vault,
      boards: boards,
      board: kb,
      user: user
    } do
      page(kb, user, "Second note")

      {:ok, first} = Tree.vault_children(vault, "board:#{kb.id}", boards, limit: 1)
      assert Enum.map(first, & &1.kind) == ["folder", "dir", "page", "more"]

      {:ok, second} =
        Tree.vault_children(vault, "board:#{kb.id}", boards, limit: 1, offset: 1)

      assert Enum.map(second, & &1.kind) == ["page"]
    end

    test "a board's folder at a mounted path holds the mounts below it", %{
      vault: vault,
      boards: boards,
      board: kb,
      notes: notes,
      idea: idea
    } do
      projects = folder(kb, "Projects")

      {:ok, rows} = Tree.vault_children(vault, "vault", boards)

      assert Enum.map(rows, &{&1.kind, &1.title}) == [
               {"folder", "Jobs"},
               {"folder", "Projects"},
               {"page", "Home note"}
             ]

      # The board's own folder, with nothing of its own in it, still opens.
      assert %{id: id, count: 1} = Enum.find(rows, &(&1.title == "Projects"))
      assert id == projects.id

      assert {:ok, [%{title: "X", key: key}]} =
               Tree.vault_children(vault, "folder:#{projects.id}", boards)

      assert key == "folder:#{notes.id}"
      assert Tree.vault_path_to(vault, idea, boards) == ["folder:#{projects.id}", key]

      result = Tree.vault_filter(vault, boards, Map.put(Slipdock.Filters.empty(), :q, "idea"))
      assert [%{title: "Projects", context: true}] = result.nodes["vault"]
      assert [%{title: "X"}] = result.nodes["folder:#{projects.id}"]
    end

    test "a board with only a folder mapped is whole, with what is mounted below the folder", %{
      vault: vault,
      boards: boards,
      user: user,
      proj: proj,
      notes: notes
    } do
      deep = board_fixture(%{"name" => "Deep", "code" => "deepvt"}, owner: user)
      page(deep, user, "Bottom")

      {:ok, _} =
        Slipdock.Vaults.add_mapping(vault, user, %{path: "/Projects/X/Deep", board: deep})

      boards = Map.put(boards, deep.id, {deep, []})

      assert Tree.vault_root(vault, proj.id, boards) == nil
      {:ok, rows} = Tree.vault_children(vault, "board:#{proj.id}", boards)
      assert Enum.map(rows, & &1.title) == ["Notes"]

      {:ok, rows} = Tree.vault_children(vault, "folder:#{notes.id}", boards)
      assert Enum.map(rows, &{&1.title, &1[:mount]}) == [{"Deep", true}, {"Idea", nil}]
    end

    test "a board mapped twice is rooted where its whole wiki is", %{
      vault: vault,
      boards: boards,
      board: kb,
      user: user,
      jobs: jobs,
      acme: acme,
      call: call
    } do
      old = folder(kb, "Old")

      {:ok, _} =
        Slipdock.Vaults.add_mapping(vault, user, %{path: "/Attic", board: kb, folder: old})

      assert Tree.vault_root(vault, kb.id, boards) == ""
      assert Tree.vault_root(vault, jobs.id, boards) == "Jobs"
      assert Tree.vault_root(vault, jobs.id, Map.delete(boards, jobs.id)) == nil

      # The way from Job Hunt's own top leaves out what is above it.
      assert Tree.vault_path_to(vault, call, boards, root: "Jobs") == ["folder:#{acme.id}"]

      assert Tree.vault_path_to(vault, call, boards, root: "") == [
               "board:#{jobs.id}",
               "folder:#{acme.id}"
             ]
    end

    test "a filter from a mount down leaves out what is above it", %{
      vault: vault,
      boards: boards,
      jobs: jobs,
      acme: acme
    } do
      q = fn text -> Map.put(Slipdock.Filters.empty(), :q, text) end

      result = Tree.vault_filter(vault, boards, q.("call"), root: "Jobs")
      assert result.top == "board:#{jobs.id}"
      assert [%{title: "Acme"}] = result.nodes["board:#{jobs.id}"]
      assert [%{title: "Call"}] = result.nodes["folder:#{acme.id}"]
      refute Map.has_key?(result.nodes, "vault")

      result = Tree.vault_filter(vault, boards, q.("home"), root: "Jobs")
      assert result.nodes == %{}
      assert result.shown == 0

      assert Tree.vault_filter(vault, boards, q.("home")).top == "vault"
    end

    test "open all names every folder in the vault", %{
      vault: vault,
      boards: boards,
      jobs: jobs,
      notes: notes,
      acme: acme
    } do
      keys = Tree.vault_folder_keys(vault, boards)

      for key <- ["board:#{jobs.id}", "dir:Projects", "folder:#{notes.id}", "folder:#{acme.id}"],
          do: assert(key in keys)
    end
  end
end
