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

  # The swimlane grid's drag names cells, `row:col`, and the move is worked out
  # from the cell it came from (#1923). Default axes: rows are priorities
  # (critical, high, medium, low, none), columns the four lists.
  describe "a swimlane drag" do
    defp swim(view, id, from, to) do
      render_hook(view, "swim_move", %{
        "id" => to_string(id),
        "from" => from,
        "to" => to,
        "before" => nil
      })
    end

    defp tag_row(board, tag) do
      Boards.get_board!(board.id).tags |> Enum.find_index(&(&1.id == tag.id)) |> to_string()
    end

    test "doesn't pull a card a runner has since finished back out of Done", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Merged", "priority" => "high"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?empty=show")

      :ok = Boards.move_card(card.id, ctx.done.id, nil)
      before = {snapshot(card), ledger(card)}

      # Drawn in high / In Progress (1:2); dragged to high / To Do (1:1).
      html = swim(view, card.id, "1:2", "1:1")

      assert {snapshot(card), ledger(card)} == before
      assert html =~ @stale
      assert Repo.get!(Card, card.id).completed
    end

    test "refuses a from that is stale on an axis other than the list", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Triaged", "priority" => "high"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?empty=show")

      {:ok, _} = Boards.update_card(Boards.get_card!(card.id), %{"priority" => "low"})

      # Drawn in high / To Do (1:1); dragged to critical / In Progress (0:2).
      html = swim(view, card.id, "1:1", "0:2")

      assert html =~ @stale
      moved = Repo.get!(Card, card.id)
      assert moved.priority == "low"
      assert moved.column_id == ctx.todo.id
    end

    test "moves as before when the from cell is still where the card is", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Next", "priority" => "high"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?empty=show")

      html = swim(view, card.id, "1:1", "0:2")

      refute html =~ @stale
      moved = Repo.get!(Card, card.id)
      assert moved.priority == "critical"
      assert moved.column_id == ctx.doing.id
    end

    test "on a tag axis, any of the card's tags is a cell it is drawn in", ctx do
      bug = tag_fixture(ctx.board, "bug")
      ui = tag_fixture(ctx.board, "ui")
      docs = tag_fixture(ctx.board, "docs")
      card = card_fixture(ctx.todo, %{"title" => "Tagged"})
      {:ok, _} = Boards.set_card_tags(Boards.get_card!(card.id), [bug, ui])

      {:ok, view, _} =
        live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?rows=tag&cols=none&empty=show")

      html =
        swim(view, card.id, tag_row(ctx.board, ui) <> ":0", tag_row(ctx.board, docs) <> ":0")

      refute html =~ @stale
      tags = Boards.get_card!(card.id).tags |> Enum.map(& &1.id) |> Enum.sort()
      assert tags == Enum.sort([bug.id, docs.id])
    end

    test "on a tag axis, a tag taken off since the tab drew it is refused", ctx do
      bug = tag_fixture(ctx.board, "bug")
      ui = tag_fixture(ctx.board, "ui")
      card = card_fixture(ctx.todo, %{"title" => "Retagged"})
      {:ok, _} = Boards.set_card_tags(Boards.get_card!(card.id), [bug])

      {:ok, view, _} =
        live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?rows=tag&cols=none&empty=show")

      {:ok, _} = Boards.set_card_tags(Boards.get_card!(card.id), [])

      html = swim(view, card.id, tag_row(ctx.board, bug) <> ":0", tag_row(ctx.board, ui) <> ":0")

      assert html =~ @stale
      assert Boards.get_card!(card.id).tags == []
    end

    test "leaves a placed page where it is now when it has moved since", ctx do
      page = page_fixture(ctx.board, %{"title" => "The spec"})
      {:ok, _} = Wiki.place(page, ctx.todo)

      {:ok, view, _} =
        live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?rows=none&cols=column&empty=show")

      {:ok, _} = Wiki.place(Wiki.get_page!(page.id), ctx.done)

      # Drawn in To Do (0:1); dragged to In Progress (0:2).
      html = swim(view, "page-#{page.id}", "0:1", "0:2")

      assert html =~ @stale
      assert Wiki.get_page!(page.id).column_id == ctx.done.id
    end
  end
end
