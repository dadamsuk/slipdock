defmodule Slipdock.DependenciesTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture()
    [backlog, todo | _] = board.columns
    a = card_fixture(backlog, %{"title" => "A"})
    b = card_fixture(backlog, %{"title" => "B"})
    c = card_fixture(todo, %{"title" => "C"})
    %{board: board, a: a, b: b, c: c}
  end

  test "adding and removing dependencies, blocked state", %{a: a, b: b, c: c, board: board} do
    assert {:ok, a} = Boards.add_dependency(a, b)
    assert Enum.map(a.blocked_by, & &1.title) == ["B"]
    assert Card.blocked?(a)
    assert Enum.map(Boards.get_card!(b.id).blocks, & &1.title) == ["A"]

    # Completing the blocker unblocks the card; archiving it does too.
    {:ok, _} = Boards.toggle_completed(b)
    refute Card.blocked?(Boards.get_card!(a.id))
    {:ok, _} = Boards.toggle_completed(Boards.get_card!(b.id))
    assert Card.blocked?(Boards.get_card!(a.id))
    {:ok, _} = Boards.archive_card(Boards.get_card!(b.id))
    refute Card.blocked?(Boards.get_card!(a.id))
    {:ok, _} = Boards.unarchive_card(Boards.get_card!(b.id))

    assert {:error, "That dependency already exists."} =
             Boards.add_dependency(Boards.get_card!(a.id), b)

    assert {:error, msg} = Boards.add_dependency(a, a)
    assert msg =~ "itself"

    # Board cards carry dependency stubs too.
    board = reload(board)
    loaded_a = board.columns |> Enum.flat_map(& &1.cards) |> Enum.find(&(&1.id == a.id))
    assert [%{title: "B"}] = loaded_a.blocked_by

    {:ok, _} = Boards.remove_dependency(Boards.get_card!(b.id), Boards.get_card!(a.id))
    assert Boards.get_card!(a.id).blocked_by == []
    assert Enum.any?(Boards.list_activities(board.id), &(&1.message =~ "depend on"))

    # Deleting a card removes its links.
    {:ok, _} = Boards.add_dependency(Boards.get_card!(a.id), c)
    {:ok, _} = Boards.delete_card(Boards.get_card!(c.id))
    assert Boards.get_card!(a.id).blocked_by == []
  end

  test "cycles are rejected", %{a: a, b: b, c: c} do
    {:ok, _} = Boards.add_dependency(a, b)
    {:ok, _} = Boards.add_dependency(b, c)
    assert {:error, msg} = Boards.add_dependency(c, a)
    assert msg =~ "circular"
  end

  describe "across boards" do
    alias Slipdock.Access

    setup %{board: board, a: a} do
      other = board_fixture(%{"name" => "Other"})
      foreign = card_fixture(hd(other.columns), %{"title" => "Elsewhere"})
      %{other: other, foreign: foreign, home: board, a: a}
    end

    test "a card can wait on a card on another board, and it is logged and broadcast on both",
         %{home: home, other: other, a: a, foreign: foreign} do
      Boards.subscribe(home.id)
      Boards.subscribe(other.id)

      assert {:ok, a} = Boards.add_dependency(a, foreign)
      assert [%{id: fid, title: "Elsewhere"}] = a.blocked_by
      assert fid == foreign.id
      assert Card.blocked?(a)
      assert [%{title: "A"}] = Boards.get_card!(foreign.id).blocks

      assert_receive {:board_changed, id} when id == home.id
      assert_receive {:board_changed, id} when id == other.id

      # Each board's log names its own card and only numbers the other.
      assert Enum.any?(
               Boards.list_activities(home.id),
               &(&1.message == "made “A” depend on card ##{foreign.id} on another board")
             )

      assert Enum.any?(
               Boards.list_activities(other.id),
               &(&1.message == "made card ##{a.id} on another board depend on “Elsewhere”")
             )

      refute Enum.any?(Boards.list_activities(other.id), &(&1.message =~ "“A”"))

      # Removing it, from the blocker's side, is logged and broadcast on both too.
      {:ok, _} = Boards.remove_dependency(Boards.get_card!(foreign.id), Boards.get_card!(a.id))
      assert Boards.get_card!(a.id).blocked_by == []
      assert_receive {:board_changed, id} when id == home.id
      assert_receive {:board_changed, id} when id == other.id

      assert Enum.any?(
               Boards.list_activities(home.id),
               &(&1.message =~ "removed the dependency between card ##{foreign.id}")
             )

      assert Enum.any?(
               Boards.list_activities(other.id),
               &(&1.message =~ "removed the dependency between “Elsewhere”")
             )
    end

    test "a cycle through three boards is refused", %{a: a, foreign: foreign} do
      third = board_fixture(%{"name" => "Third"})
      t = card_fixture(hd(third.columns), %{"title" => "Third card"})

      {:ok, _} = Boards.add_dependency(a, foreign)
      {:ok, _} = Boards.add_dependency(foreign, t)
      assert {:error, msg} = Boards.add_dependency(t, a)
      assert msg =~ "circular"
      assert Boards.get_card!(t.id).blocked_by == []
    end

    test "--deps ready, blocked state and the rollup hold across boards",
         %{home: home, a: a, foreign: foreign} do
      {:ok, _} = Boards.add_dependency(a, foreign)
      titles = fn deps -> Boards.list_cards(home, %{"deps" => deps}) |> Enum.map(& &1.title) end

      assert "A" in titles.("blocked")
      refute "A" in titles.("ready")

      {:ok, _} = Boards.toggle_completed(Boards.get_card!(foreign.id))
      refute "A" in titles.("blocked")
      assert "A" in titles.("ready")
    end

    test "a reader who can't see the other board sees a hidden stub, still blocked",
         %{home: home, a: a, foreign: foreign} do
      reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
      share_fixture(home, reader, "read")
      {:ok, _} = Boards.add_dependency(a, foreign)

      card = Access.hide_unreadable_dependencies(reader, Boards.get_card!(a.id))

      assert [%Card{id: fid, hidden: true, title: "A card you can't see", board_id: nil}] =
               card.blocked_by

      assert fid == foreign.id
      assert Card.blocked?(card)

      # The owner, who can read both, sees it as it is.
      owner_view = Access.hide_unreadable_dependencies(user_fixture(), Boards.get_card!(a.id))
      assert [%{hidden: false, title: "Elsewhere"}] = owner_view.blocked_by

      # The same over a whole board.
      board = Access.hide_unreadable_dependencies(reader, Boards.get_board!(home.id))
      loaded = board.columns |> Enum.flat_map(& &1.cards) |> Enum.find(&(&1.id == a.id))
      assert [%{hidden: true}] = loaded.blocked_by

      # And on the blocker's side, for somebody who can only see that board.
      far = user_fixture("far-#{System.unique_integer([:positive])}@example.com")
      share_fixture(Boards.get_board!(foreign.board_id), far, "read")
      blocker = Access.hide_unreadable_dependencies(far, Boards.get_card!(foreign.id))
      assert [%{hidden: true, title: "A card you can't see"}] = blocker.blocks

      # A token scoped to one board hides cards on the other, even for the owner.
      scoped = %{scope: "write", scope_boards: [home.id]}
      card = Access.hide_unreadable_dependencies(user_fixture(), Boards.get_card!(a.id), scoped)
      assert [%{hidden: true}] = card.blocked_by
    end

    test "nothing to hide is left alone, and nobody signed in sees nothing", %{a: a, b: b} do
      assert [%Card{blocked_by: []}] =
               Access.hide_unreadable_dependencies(user_fixture(), [Boards.get_card!(a.id)])

      {:ok, _} = Boards.add_dependency(a, b)
      owner_view = Access.hide_unreadable_dependencies(user_fixture(), Boards.get_card!(a.id))
      assert [%{title: "B", hidden: false}] = owner_view.blocked_by

      assert [%{hidden: true}] =
               Access.hide_unreadable_dependencies(nil, Boards.get_card!(a.id)).blocked_by
    end
  end

  test "search excludes the card itself and given ids", %{board: board, a: a, b: b} do
    assert Enum.map(Boards.search_cards(board.id, "", [a.id]), & &1.title) == ["B", "C"]
    assert Enum.map(Boards.search_cards(board.id, "c", [a.id, b.id]), & &1.title) == ["C"]
  end

  test "swimlane dependencies axis and filter", %{board: board, a: a, b: b} do
    {:ok, _} = Boards.add_dependency(a, b)
    board = reload(board)

    grid = Swimlanes.grid(board, %Config{rows: "dependencies", cols: "none"})

    assert Enum.map(grid.rows, &{&1.label, Enum.map(hd(&1.cells), fn c -> c.title end)}) ==
             [{"Blocked", ["A"]}, {"Blocks others", ["B"]}, {"No dependencies", ["C"]}]

    titles = fn deps ->
      Swimlanes.grid(board, %Config{rows: "none", cols: "none", deps: deps}).rows
      |> hd()
      |> Map.get(:cells)
      |> hd()
      |> Enum.map(& &1.title)
    end

    assert titles.("blocked") == ["A"]
    assert titles.("ready") == ["B", "C"]
    assert titles.("blocking") == ["B"]
    assert titles.("free") == ["C"]

    assert [{:error, _}] = Swimlanes.move_ops("dependencies", a, "free", "blocked", %Config{})
    assert Config.from_query(%{"deps" => "blocked"}).deps == "blocked"
    assert Config.from_query(%{"deps" => "bogus"}).deps == nil
  end
end
