defmodule Slipdock.FavouritesTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Favourites}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Plan"}, owner: user)
    [backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Write the post"})

    {:ok, view} =
      Boards.create_saved_view(board, %{"name" => "By tag", "config" => %{"rows" => "tag"}})

    %{user: user, board: board, backlog: backlog, todo: todo, card: card, view: view}
  end

  test "toggling adds, then removes", %{user: user, card: card} do
    refute Favourites.favourite?(Favourites.marks(user), :card, card.id)

    assert {:ok, :added} = Favourites.toggle(user, :card, card.id)
    assert Favourites.favourite?(Favourites.marks(user), :card, card.id)
    assert Favourites.count(user) == 1

    assert {:ok, :removed} = Favourites.toggle(user, :card, card.id)
    refute Favourites.favourite?(Favourites.marks(user), :card, card.id)
    assert Favourites.count(user) == 0
  end

  test "add and remove are idempotent", %{user: user, todo: todo} do
    assert {:ok, :added} = Favourites.add(user, :column, todo.id)
    assert {:ok, :unchanged} = Favourites.add(user, :column, todo.id)
    assert Favourites.count(user) == 1

    assert {:ok, :removed} = Favourites.remove(user, :column, todo.id)
    assert {:ok, :unchanged} = Favourites.remove(user, :column, todo.id)
    assert Favourites.count(user) == 0
  end

  test "every kind lands in the list, with its board", %{
    user: user,
    board: board,
    todo: todo,
    card: card,
    view: view
  } do
    for {kind, id} <- [{:board, board.id}, {:column, todo.id}, {:card, card.id}, {:view, view.id}],
        do: assert({:ok, :added} = Favourites.toggle(user, kind, id))

    entries = Favourites.list(user)
    assert Enum.map(entries, & &1.kind) == [:board, :column, :card, :view]
    assert Enum.all?(entries, &(&1.board.id == board.id))

    assert %{resource: %{title: "Write the post"}} = Enum.find(entries, &(&1.kind == :card))
    assert %{resource: %{name: "By tag"}} = Enum.find(entries, &(&1.kind == :view))
  end

  test "they are one person's, not the board's", %{user: user, board: board, card: card} do
    other = user_fixture("someone-else@example.com")
    {:ok, _} = Access.grant(board, other, "read", user)

    {:ok, :added} = Favourites.toggle(user, :card, card.id)

    assert Favourites.count(user) == 1
    assert Favourites.count(other) == 0
    assert Favourites.list(other) == []

    # …and the same card can be favourited again, by them.
    assert {:ok, :added} = Favourites.toggle(other, :card, card.id)
    assert [%{kind: :card}] = Favourites.list(other)
  end

  test "you cannot favourite what you cannot read", %{card: card, todo: todo} do
    stranger = user_fixture("stranger@example.com")

    assert {:error, :not_found} = Favourites.toggle(stranger, :card, card.id)
    assert {:error, :not_found} = Favourites.toggle(stranger, :column, todo.id)
    assert Favourites.count(stranger) == 0
  end

  test "access lost after the fact drops the row from the list", %{
    user: user,
    board: board,
    card: card
  } do
    other = user_fixture("later@example.com")
    {:ok, grant} = Access.grant(board, other, "read", user)
    {:ok, :added} = Favourites.toggle(other, :card, card.id)
    assert [%{kind: :card}] = Favourites.list(other)

    Access.revoke(grant)
    assert Favourites.list(other) == []
  end

  test "an archived card is no longer somewhere to go", %{user: user, card: card} do
    {:ok, :added} = Favourites.toggle(user, :card, card.id)
    assert [%{kind: :card}] = Favourites.list(user)

    {:ok, _} = Boards.archive_card(card)
    assert Favourites.list(user) == []

    # Restoring brings it back: the row was never deleted.
    {:ok, _} = Boards.unarchive_card(Boards.get_card!(card.id))
    assert [%{kind: :card}] = Favourites.list(user)
  end

  test "deleting the thing deletes the favourite", %{user: user, backlog: backlog, view: view} do
    {:ok, :added} = Favourites.toggle(user, :column, backlog.id)
    {:ok, :added} = Favourites.toggle(user, :view, view.id)
    assert Favourites.count(user) == 2

    {:ok, _} = Boards.delete_saved_view(view)
    assert Favourites.count(user) == 1
    assert [%{kind: :column}] = Favourites.list(user)
  end

  test "kinds are read off the wire safely" do
    assert Favourites.kind("card") == {:ok, :card}
    assert Favourites.kind(:view) == {:ok, :view}
    assert Favourites.kind("nonsense") == :error
    assert Favourites.kind(nil) == :error
  end
end
