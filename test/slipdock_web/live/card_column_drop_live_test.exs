defmodule SlipdockWeb.CardColumnDropLiveTest do
  @moduledoc """
  Dropping a card anywhere in another list's column (#827). The browser works
  out where the pointer was (assets/js/card_drop.js, with its own node tests
  and tools/e2e/card-column-drop.sh); the board has to mark which lists take
  such drops, and a drop outside the cards arrives as a move with no `before`,
  which must put the card at the bottom of that list.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Dropping"}, owner: user)
    [from, to | _] = board.columns
    %{board: board, from: from, to: to}
  end

  test "every list on the board takes drops on its column, inside the board area", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    assert has_element?(view, "#board-scroll[data-drop-area]")

    for column <- ctx.board.columns do
      assert has_element?(view, ~s|#cards-#{column.id}[data-column-drop=".kanban-column"]|)
      assert has_element?(view, "#column-#{column.id}.kanban-column")
    end
  end

  test "a card dropped outside another list's cards goes to its bottom", ctx do
    first = card_fixture(ctx.to, %{"title" => "First"})
    second = card_fixture(ctx.to, %{"title" => "Second"})
    moved = card_fixture(ctx.from, %{"title" => "Moved"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    render_hook(view, "move_card", %{
      "id" => "#{moved.id}",
      "from" => "#{ctx.from.id}",
      "to" => "#{ctx.to.id}",
      "before" => nil
    })

    order = Boards.active_items(ctx.to.id)
    assert order == [{:card, first.id}, {:card, second.id}, {:card, moved.id}]
    assert Repo.get!(Card, moved.id).column_id == ctx.to.id
  end
end
