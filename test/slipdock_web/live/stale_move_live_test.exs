defmodule SlipdockWeb.StaleMoveLiveTest do
  @moduledoc """
  A move from a tab whose view is stale (#1921). The browser says which list
  it drew the item in (`from`); when that isn't where the item is now, the
  server refuses the move, says so, and redraws the board, rather than
  dragging a card the runner has since finished back into progress.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Wiki}
  alias Slipdock.Boards.{Activity, Card, CardMove}

  @stale "That has moved since this board was drawn"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Stale tabs"}, owner: user)
    [backlog, todo, doing, done] = board.columns
    %{board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp move(view, id, from, to, before \\ nil) do
    render_hook(view, "move_card", %{
      "id" => to_string(id),
      "from" => to_string(from),
      "to" => to_string(to),
      "before" => before
    })
  end

  defp ledger(card) do
    {Repo.aggregate(from(a in Activity, where: a.card_id == ^card.id), :count),
     Repo.aggregate(from(m in CardMove, where: m.card_id == ^card.id), :count)}
  end

  defp snapshot(card) do
    card = Repo.get!(Card, card.id)
    Map.take(card, [:column_id, :position, :completed, :completed_at, :percent_complete])
  end

  test "a stale drag inside In Progress doesn't pull a done card back out of Done", ctx do
    other = card_fixture(ctx.doing, %{"title" => "Still going"})
    card = card_fixture(ctx.doing, %{"title" => "Merged"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    # The runner finishes it while the phone's tab still shows it in progress.
    :ok = Boards.move_card(card.id, ctx.done.id, nil)
    done = Repo.get!(Card, card.id)
    assert done.completed and done.column_id == ctx.done.id
    before = {snapshot(card), ledger(card)}

    # The buffered swipe: a small reorder in In Progress, sent on rejoin.
    html = move(view, card.id, ctx.doing.id, ctx.doing.id, to_string(other.id))

    assert {snapshot(card), ledger(card)} == before
    assert html =~ @stale
    # The redrawn board shows it where it is now.
    assert has_element?(view, "#cards-#{ctx.done.id} [data-id='#{card.id}']")
    refute has_element?(view, "#cards-#{ctx.doing.id} [data-id='#{card.id}']")
  end

  test "a stale move between two other lists is refused too", ctx do
    card = card_fixture(ctx.backlog, %{"title" => "Picked"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    :ok = Boards.move_card(card.id, ctx.todo.id, nil)
    before = {snapshot(card), ledger(card)}

    html = move(view, card.id, ctx.backlog.id, ctx.doing.id)

    assert {snapshot(card), ledger(card)} == before
    assert html =~ @stale
  end

  test "a move whose from matches moves the card as before", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Next"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    {acts, moves} = ledger(card)

    html = move(view, card.id, ctx.todo.id, ctx.doing.id)

    refute html =~ @stale
    assert Repo.get!(Card, card.id).column_id == ctx.doing.id
    assert ledger(card) == {acts + 1, moves + 1}
  end

  test "a matching reorder in the same list still reorders", ctx do
    first = card_fixture(ctx.todo, %{"title" => "First"})
    second = card_fixture(ctx.todo, %{"title" => "Second"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    move(view, second.id, ctx.todo.id, ctx.todo.id, to_string(first.id))

    assert Boards.active_items(ctx.todo.id) == [card: second.id, card: first.id]
  end

  test "a matching move out of Done into a doing list still reopens the card", ctx do
    card = card_fixture(ctx.doing, %{"title" => "Not quite"})
    :ok = Boards.move_card(card.id, ctx.done.id, nil)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    html = move(view, card.id, ctx.done.id, ctx.doing.id)

    refute html =~ @stale
    reopened = Repo.get!(Card, card.id)
    assert reopened.column_id == ctx.doing.id
    refute reopened.completed
  end

  test "the Move to menu says which list it drew the card in", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Menu"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    assert has_element?(
             view,
             ~s|button[phx-click="move_card"][phx-value-id="#{card.id}"][phx-value-from="#{ctx.todo.id}"][phx-value-to="#{ctx.doing.id}"]|
           )
  end

  test "a move with no from, from an older bundle, still moves", ctx do
    card = card_fixture(ctx.todo, %{"title" => "Old tab"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    render_hook(view, "move_card", %{"id" => "#{card.id}", "to" => "#{ctx.doing.id}"})

    assert Repo.get!(Card, card.id).column_id == ctx.doing.id
  end

  describe "a placed page" do
    setup ctx do
      page = page_fixture(ctx.board, %{"title" => "The spec"})
      {:ok, _} = Wiki.place(page, ctx.todo)
      %{page: page}
    end

    test "moves when its from matches", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      html = move(view, "page-#{ctx.page.id}", ctx.todo.id, ctx.doing.id)

      refute html =~ @stale
      assert Wiki.get_page!(ctx.page.id).column_id == ctx.doing.id
    end

    test "stays put when it has moved since the tab drew it", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      {:ok, _} = Wiki.place(Wiki.get_page!(ctx.page.id), ctx.done)

      html = move(view, "page-#{ctx.page.id}", ctx.todo.id, ctx.doing.id)

      assert html =~ @stale
      assert Wiki.get_page!(ctx.page.id).column_id == ctx.done.id
      assert has_element?(view, "#cards-#{ctx.done.id} [data-id='page-#{ctx.page.id}']")
    end
  end
end
