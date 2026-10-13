defmodule Slipdock.WikiTreeTest do
  @moduledoc """
  The tree a browser draws, one container at a time (W-103 R11.1): what each
  container holds, in what order, what each row says, and that no body is
  ever read for it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

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
end
