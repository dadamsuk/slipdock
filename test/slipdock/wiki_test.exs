defmodule Slipdock.WikiTest do
  @moduledoc """
  The wiki's domain rules: codes and slugs, the tree, history, and the two
  things that stop two writers losing each other's work — the base-hash
  conflict and the revision written on every save.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.Page

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Wiki Test", "code" => "wikitest"}, owner: user)
    %{user: user, board: board}
  end

  describe "creating" do
    test "takes a slug off the title and a code of its own", %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      assert page.slug == "retry-policy"
      assert page.code =~ ~r/^W-\d+$/
      assert page.number == 1
      assert page.content_hash == Page.hash("")
    end

    test "numbers pages per board but keeps codes unique across them", %{user: user} do
      a = board_fixture(%{"name" => "Alpha"}, owner: user)
      b = board_fixture(%{"name" => "Beta"}, owner: user)

      {:ok, first} = Wiki.create_page(a, %{"title" => "One"}, user: user)
      {:ok, second} = Wiki.create_page(b, %{"title" => "Two"}, user: user)

      assert first.number == 1
      assert second.number == 1
      refute first.code == second.code
    end

    test "a clashing slug gets a number rather than a failure", %{board: board, user: user} do
      {:ok, _} = Wiki.create_page(board, %{"title" => "Runbook"}, user: user)
      {:ok, second} = Wiki.create_page(board, %{"title" => "Runbook"}, user: user)

      assert second.slug == "runbook-2"
    end

    test "writes the first revision, with who wrote it and why", %{board: board, user: user} do
      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Spec", "body" => "hello"},
          user: user,
          via: "cli",
          agent: "claude",
          message: "started it"
        )

      assert [revision] = Wiki.list_revisions(page)
      assert revision.body == "hello"
      assert revision.via == "cli"
      assert revision.agent == "claude"
      assert revision.summary == "started it"
      assert revision.author_id == user.id
    end
  end

  describe "finding" do
    setup %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)
      %{page: page}
    end

    test "by id, code and board/slug", %{board: board, page: page} do
      assert {:ok, %Page{id: id}} = Wiki.find_page(page.id)
      assert id == page.id
      assert {:ok, %Page{id: ^id}} = Wiki.find_page(page.code)
      assert {:ok, %Page{id: ^id}} = Wiki.find_page(String.downcase(page.code))
      assert {:ok, %Page{id: ^id}} = Wiki.find_page("#{board.code}/retry-policy")
    end

    test "on a board, by slug or title, case-insensitively", %{board: board, page: page} do
      assert {:ok, %Page{id: id}} = Wiki.find_page(board, "retry-policy")
      assert id == page.id
      assert {:ok, %Page{id: ^id}} = Wiki.find_page(board, "Retry POLICY")
    end

    test "a title that does not exist is not found", %{board: board} do
      assert {:error, :not_found, _} = Wiki.find_page(board, "nothing here")
    end

    test "a rename does not break the code", %{page: page, user: user} do
      {:ok, renamed} =
        Wiki.update_page(page, %{"title" => "Retries", "slug" => "retries"}, user: user)

      assert renamed.code == page.code
      assert {:ok, found} = Wiki.find_page(page.code)
      assert found.title == "Retries"
    end
  end

  describe "the tree" do
    test "nests children under parents and keeps siblings ordered", %{board: board, user: user} do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Deploys"}, user: user)

      {:ok, child} =
        Wiki.create_page(board, %{"title" => "Rollback", "parent_id" => parent.id}, user: user)

      assert [%{page: top, children: [%{page: under}]}] = Wiki.tree(board)
      assert top.id == parent.id
      assert under.id == child.id
      assert Wiki.ancestors(child) |> Enum.map(& &1.id) == [parent.id]
    end

    test "refuses a parent on another board", %{board: board, user: user} do
      other = board_fixture(%{"name" => "Elsewhere"}, owner: user)
      {:ok, elsewhere} = Wiki.create_page(other, %{"title" => "Away"}, user: user)

      assert {:error, changeset} =
               Wiki.create_page(board, %{"title" => "Here", "parent_id" => elsewhere.id},
                 user: user
               )

      assert "is not a page on this board" in errors_on(changeset).parent_id
    end

    test "refuses a cycle", %{board: board, user: user} do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Top"}, user: user)

      {:ok, child} =
        Wiki.create_page(board, %{"title" => "Under", "parent_id" => parent.id}, user: user)

      assert {:error, changeset} =
               Wiki.update_page(parent, %{"parent_id" => child.id}, user: user)

      assert "is beneath it" in errors_on(changeset).parent_id
    end

    test "moving reorders among siblings", %{board: board, user: user} do
      {:ok, a} = Wiki.create_page(board, %{"title" => "A"}, user: user)
      {:ok, b} = Wiki.create_page(board, %{"title" => "B"}, user: user)
      {:ok, c} = Wiki.create_page(board, %{"title" => "C"}, user: user)

      {:ok, _} = Wiki.move_page(c, nil, 0, user: user)

      assert Wiki.list_pages(board) |> Enum.map(& &1.id) == [c.id, a.id, b.id]
    end
  end

  describe "saving" do
    setup %{board: board, user: user} do
      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Runbook", "body" => "one"}, user: user)

      %{page: page}
    end

    test "a matching base hash is accepted", %{page: page, user: user} do
      assert {:ok, saved} =
               Wiki.update_page(page, %{"body" => "two"},
                 user: user,
                 base_hash: page.content_hash
               )

      assert saved.body == "two"
      assert saved.content_hash == Page.hash("two")
    end

    test "a stale base hash is refused, with the page as it now stands", %{
      page: page,
      user: user
    } do
      other = user_fixture("someone.else@example.com")
      {:ok, _} = Wiki.update_page(page, %{"body" => "theirs"}, user: other)

      assert {:error, :conflict, current} =
               Wiki.update_page(page, %{"body" => "mine"},
                 user: user,
                 base_hash: page.content_hash
               )

      assert current.body == "theirs"
      assert current.content_hash == Page.hash("theirs")
      assert Wiki.get_page!(page.id).body == "theirs"
    end

    test "no base hash means last write wins, recoverably", %{page: page, user: user} do
      {:ok, saved} = Wiki.update_page(page, %{"body" => "two"}, user: user)
      assert saved.body == "two"
      assert Enum.any?(Wiki.list_revisions(saved), &(&1.body == "two"))
    end

    test "consecutive saves by one hand collapse into one revision", %{
      page: page,
      user: user
    } do
      {:ok, page} = Wiki.update_page(page, %{"body" => "two"}, user: user)
      {:ok, page} = Wiki.update_page(page, %{"body" => "three"}, user: user)

      assert [only] = Wiki.list_revisions(page)
      assert only.body == "three"
    end

    test "a different writer starts a revision of their own", %{page: page, user: user} do
      other = user_fixture("other.writer@example.com")
      {:ok, page} = Wiki.update_page(page, %{"body" => "theirs"}, user: other)

      assert [newest, first] = Wiki.list_revisions(page)
      assert newest.author_id == other.id
      assert first.author_id == user.id
    end

    test "moving a page is not an edit of the document", %{board: board, page: page, user: user} do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Parent"}, user: user)
      before = length(Wiki.list_revisions(page))

      {:ok, _} = Wiki.move_page(page, parent, :bottom, user: user)

      assert length(Wiki.list_revisions(page)) == before
    end
  end

  describe "history" do
    test "reverting is a save, not a deletion", %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Doc", "body" => "first"}, user: user)
      [first] = Wiki.list_revisions(page)

      other = user_fixture("later@example.com")
      {:ok, page} = Wiki.update_page(page, %{"body" => "second"}, user: other)

      {:ok, reverted} = Wiki.revert_page(page, first, user: user, message: "put it back")

      assert reverted.body == "first"
      bodies = Wiki.list_revisions(reverted) |> Enum.map(& &1.body)
      assert "second" in bodies
      assert "first" in bodies
    end

    test "undoing your own edit at once keeps the edit in history", %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Doc", "body" => "first"}, user: user)
      [first] = Wiki.list_revisions(page)
      other = user_fixture("between@example.com")
      {:ok, page} = Wiki.update_page(page, %{"body" => "second"}, user: other)
      {:ok, page} = Wiki.update_page(page, %{"body" => "clobbered"}, user: user)

      {:ok, _} = Wiki.revert_page(page, first, user: user)

      # A quick second save by the same hand would fold into "clobbered".
      assert Wiki.list_revisions(page) |> Enum.map(& &1.body) ==
               ["first", "clobbered", "second", "first"]
    end

    test "diffs are hunks of equal, deleted and inserted lines" do
      assert Wiki.diff("a\nb\nc", "a\nx\nc") == [eq: ["a"], del: ["b"], ins: ["x"], eq: ["c"]]
      # From nothing is all insertion; to nothing all deletion.
      assert Wiki.diff("", "a\nb") == [ins: ["a", "b"]]
      assert Wiki.diff("a", "") == [del: ["a"]]
    end
  end

  describe "split_diff/2" do
    defp eq(n, m, line),
      do: {:row, %{n: n, op: :eq, parts: [{:eq, line}]}, %{n: m, op: :eq, parts: [{:eq, line}]}}

    test "an edited line sits beside its replacement, the changed words picked out" do
      assert Wiki.split_diff("intro\nthe quick brown fox\nend", "intro\nthe quick red fox\nend") ==
               [
                 eq(1, 1, "intro"),
                 {:row, %{n: 2, op: :del, parts: [eq: "the quick ", chg: "brown", eq: " fox"]},
                  %{n: 2, op: :ins, parts: [eq: "the quick ", chg: "red", eq: " fox"]}},
                 eq(3, 3, "end")
               ]
    end

    test "lines with little in common are marked whole, not word by word" do
      assert [
               {:row, %{op: :del, parts: [eq: "alpha beta gamma"]},
                %{op: :ins, parts: [eq: "one two three"]}}
             ] =
               Wiki.split_diff("alpha beta gamma", "one two three")
    end

    test "an uneven replacement trails against blanks, and numbers count each side" do
      assert [
               a,
               {:row, %{n: 2, op: :del}, %{n: 2, op: :ins}},
               {:row, %{n: 3, op: :del, parts: [eq: "c"]}, nil},
               d,
               {:row, nil, %{n: 4, op: :ins, parts: [eq: "e"]}}
             ] = Wiki.split_diff("a\nb\nc\nd", "a\nB\nd\ne")

      assert a == eq(1, 1, "a")
      assert d == eq(4, 3, "d")
    end

    test "from nothing is all right-hand side; to nothing all left" do
      assert Wiki.split_diff("", "a\nb") == [
               {:row, nil, %{n: 1, op: :ins, parts: [eq: "a"]}},
               {:row, nil, %{n: 2, op: :ins, parts: [eq: "b"]}}
             ]

      assert Wiki.split_diff("a", "") == [{:row, %{n: 1, op: :del, parts: [eq: "a"]}, nil}]
      assert Wiki.split_diff("", "") == []
    end

    test "long unchanged runs fold away, keeping three lines next to each change" do
      old = Enum.map_join(1..20, "\n", &"line #{&1}")
      new = String.replace(old, "line 10\n", "line ten\n")

      rows = Wiki.split_diff(old, new)

      # Lines 1–6 fold (nothing above them to keep context for), 7–9 stay,
      # the change, 11–13 stay, 14–20 fold.
      assert [{:fold, top}, _, _, _, {:row, %{op: :del}, %{op: :ins}}, _, _, _, {:fold, bottom}] =
               rows

      assert length(top) == 6
      assert hd(top) == eq(1, 1, "line 1")
      assert length(bottom) == 7
      assert List.last(bottom) == eq(20, 20, "line 20")
    end

    test "a short unchanged run is not worth folding" do
      old = "a\nb\nc\nd\ne\nf\ng\nh"
      new = "A\nb\nc\nd\ne\nf\ng\nH"

      refute Enum.any?(Wiki.split_diff(old, new), &match?({:fold, _}, &1))
    end

    test "identical texts fold into one run" do
      text = Enum.map_join(1..5, "\n", &"l#{&1}")
      assert [{:fold, rows}] = Wiki.split_diff(text, text)
      assert length(rows) == 5
    end

    test "very long lines are marked whole rather than word-diffed" do
      old = String.duplicate("word ", 300)
      new = old <> "more"

      assert [{:row, %{parts: [eq: ^old]}, %{parts: [eq: ^new]}}] = Wiki.split_diff(old, new)
    end
  end

  describe "archiving" do
    test "takes the children with it and brings them back", %{board: board, user: user} do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Parent"}, user: user)

      {:ok, child} =
        Wiki.create_page(board, %{"title" => "Child", "parent_id" => parent.id}, user: user)

      {:ok, _} = Wiki.archive_page(parent)

      assert Wiki.list_pages(board) == []
      assert Wiki.get_page!(child.id).archived_at

      {:ok, _} = Wiki.unarchive_page(Wiki.get_page!(parent.id))
      refute Wiki.get_page!(child.id).archived_at
    end

    test "purging leaves the children behind rather than taking them", %{
      board: board,
      user: user
    } do
      {:ok, parent} = Wiki.create_page(board, %{"title" => "Parent"}, user: user)

      {:ok, child} =
        Wiki.create_page(board, %{"title" => "Child", "parent_id" => parent.id}, user: user)

      {:ok, _} = Wiki.delete_page(parent)

      assert %Page{parent_id: nil} = Wiki.get_page!(child.id)
    end
  end

  describe "permissions" do
    setup %{board: board, user: user} do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)
      {:ok, page} = Wiki.create_page(board, %{"title" => "Shared"}, user: user)
      %{reader: reader, page: page}
    end

    test "a page inherits the board's permission", %{page: page, reader: reader, user: user} do
      assert Access.page_permission(user, page) == :owner
      assert Access.page_permission(reader, page) == :read
    end

    test "a grant on the page alone raises it", %{page: page, reader: reader, user: user} do
      {:ok, _} = Access.grant(page, reader, "write", user)
      assert Access.page_permission(reader, page) == :write
    end

    test "a page grant reaches the page without the board", %{board: board, user: user} do
      outsider = user_fixture("outsider@example.com")
      {:ok, page} = Wiki.create_page(board, %{"title" => "Just this"}, user: user)

      assert Access.page_permission(outsider, page) == :none
      {:ok, _} = Access.grant(page, outsider, "read", user)

      assert Access.page_permission(outsider, page) == :read
      assert Access.board_permission(outsider, board) == :none
      assert [%Page{}] = Access.shared_pages(outsider)
    end

    test "a draft is invisible to a reader and visible to a writer", %{
      board: board,
      reader: reader,
      user: user
    } do
      {:ok, draft} =
        Wiki.create_page(board, %{"title" => "Half written", "status" => "draft"}, user: user)

      refute Wiki.visible?(draft, Access.page_permission(reader, draft))
      assert Wiki.visible?(draft, Access.page_permission(user, draft))
    end
  end
end
