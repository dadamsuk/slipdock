defmodule Slipdock.WikiPlacementTest do
  @moduledoc """
  A wiki page put on the board: in a list, in one order with the cards, and
  draggable between lists like a card.

  The property that matters is the **shared position sequence**. A page that
  could only sit after every card would not really be on the board, so both
  move operations repack the list's contents together.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Wiki}
  alias Slipdock.Wiki.Page

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Placed", "code" => "placed"}, owner: user)
    [todo, doing | _] = board.columns

    %{
      user: user,
      board: board,
      todo: todo,
      doing: doing,
      one: card_fixture(todo, %{"title" => "One"}),
      two: card_fixture(todo, %{"title" => "Two"})
    }
  end

  defp order(column), do: Boards.active_items(column.id)

  describe "placing" do
    test "puts a page at the end of a list, and takes it off again", %{
      board: board,
      todo: todo,
      user: user,
      one: one,
      two: two
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)

      refute Page.placed?(page)
      {:ok, placed} = Wiki.place(page, todo)

      assert Page.placed?(placed)
      assert placed.column_id == todo.id
      assert order(todo) == [card: one.id, card: two.id, page: page.id]

      {:ok, unplaced} = Wiki.unplace(placed)
      refute Page.placed?(unplaced)
      assert order(todo) == [card: one.id, card: two.id]

      # Off the board, but exactly where it was in the wiki.
      assert [%{page: %{id: id}}] = Wiki.tree(board)
      assert id == page.id
    end

    test "sits between two cards, not after them", %{
      board: board,
      todo: todo,
      user: user,
      one: one,
      two: two
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)
      {:ok, _} = Wiki.place(page, todo, two.id)

      assert order(todo) == [card: one.id, page: page.id, card: two.id]
    end

    test "a card can be dropped either side of it", %{
      board: board,
      todo: todo,
      user: user,
      one: one,
      two: two
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)
      {:ok, _} = Wiki.place(page, todo, one.id)
      assert order(todo) == [page: page.id, card: one.id, card: two.id]

      # The drag sends `page-<id>` back, which is what the board reads.
      Boards.move_card(two.id, todo.id, "page-#{page.id}")
      assert order(todo) == [card: two.id, page: page.id, card: one.id]

      Boards.move_card(two.id, todo.id, nil)
      assert order(todo) == [page: page.id, card: one.id, card: two.id]
    end

    test "moves between lists, closing the one it left", %{
      board: board,
      todo: todo,
      doing: doing,
      user: user,
      one: one,
      two: two
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)
      {:ok, placed} = Wiki.place(page, todo, one.id)
      {:ok, moved} = Wiki.place(placed, doing)

      assert moved.column_id == doing.id
      assert order(todo) == [card: one.id, card: two.id]
      assert order(doing) == [page: page.id]

      # Positions close up rather than leaving gaps behind.
      assert Enum.map(Boards.get_board!(board.id).columns, & &1.id) != []
      assert Boards.get_card!(one.id).position == 0
      assert Boards.get_card!(two.id).position == 1
    end

    test "refuses a list on another board", %{board: board, user: user} do
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: user)
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)

      assert {:error, :unprocessable_entity, message} =
               Wiki.place(page, hd(elsewhere.columns))

      assert message =~ "a list on another board"
    end

    test "an index counts the pages as well as the cards", %{
      board: board,
      todo: todo,
      user: user,
      one: one,
      two: two
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)
      {:ok, _} = Wiki.place(page, todo, two.id)
      assert order(todo) == [card: one.id, page: page.id, card: two.id]

      # "Second from the top" is what the reader sees, not what the cards
      # table says: index 1 is the page's slot.
      three = card_fixture(todo, %{"title" => "Three"})
      :ok = Boards.move_card_to_index(three, todo, 1)

      assert order(todo) == [card: one.id, card: three.id, page: page.id, card: two.id]
    end
  end

  describe "what the board is given" do
    test "a loaded board carries its placed pages on the lists", %{
      board: board,
      todo: todo,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)
      {:ok, _} = Wiki.place(page, todo)

      loaded = Boards.get_board!(board.id)
      column = Enum.find(loaded.columns, &(&1.id == todo.id))

      assert [%Page{title: "The spec"}] = column.pages
      assert Enum.all?(loaded.columns -- [column], &(&1.pages == []))
    end

    test "an archived page leaves the board and comes back to it", %{
      board: board,
      todo: todo,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)
      {:ok, placed} = Wiki.place(page, todo)

      {:ok, _} = Wiki.archive_page(placed)
      assert order(todo) |> Enum.all?(&match?({:card, _}, &1))
      assert Wiki.placed_in(todo.id) == []

      {:ok, restored} = Wiki.unarchive_page(Wiki.get_page!(page.id))
      assert restored.column_id == todo.id
      assert [%Page{}] = Wiki.placed_in(todo.id)
    end

    test "deleting a list leaves its pages behind, unplaced", %{
      board: board,
      todo: todo,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "The spec"}, user: user)
      {:ok, _} = Wiki.place(page, todo)

      {:ok, _} = Boards.delete_column(Boards.get_column!(todo.id))

      assert %Page{column_id: nil} = Wiki.get_page!(page.id)
      assert [%{page: %{title: "The spec"}}] = Wiki.tree(board)
    end
  end

  describe "reading a drag" do
    test "tells a card from a page, and refuses nonsense" do
      assert Boards.item_ref("12") == {:card, 12}
      assert Boards.item_ref(12) == {:card, 12}
      assert Boards.item_ref("page-7") == {:page, 7}
      assert Boards.item_ref({:page, 7}) == {:page, 7}
      assert Boards.item_ref("") == nil
      assert Boards.item_ref(nil) == nil
      assert Boards.item_ref("page-") == nil
      assert Boards.item_ref("nonsense") == nil
    end
  end
end
