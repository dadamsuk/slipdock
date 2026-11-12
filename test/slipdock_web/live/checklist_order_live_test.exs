defmodule SlipdockWeb.ChecklistOrderLiveTest do
  @moduledoc """
  Dragging checklist items into a new order (#1752): the list wears the
  `Sortable` hook and a handle for writers, the `move_check` event it pushes
  reorders the card's (or page's) items, and a reader can't.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Order UI"}, owner: user)
    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "Steps"})

    [one, two, three] =
      for text <- ~w(alpha bravo charlie) do
        {:ok, item} = Boards.Checklists.add_checklist_item(card, text)
        item
      end

    %{board: board, col: col, card: card, one: one, two: two, three: three}
  end

  defp texts(owner),
    do:
      owner
      |> Repo.preload(:checklist_items, force: true)
      |> Map.fetch!(:checklist_items)
      |> Enum.map(& &1.text)

  defp card_panel(view), do: with_target(view, "#board-card")

  test "a writer's checklist is sortable by its handle", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    assert has_element?(
             view,
             ~s(ul#checklist-items[phx-hook="Sortable"][data-event="move_check"][data-push-to="self"][data-disabled="false"])
           )

    assert has_element?(view, ~s(li#check-#{ctx.one.id}[data-id="#{ctx.one.id}"] .check-handle))
  end

  test "move_check puts an item before another, then at the end", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    render_hook(card_panel(view), "move_check", %{
      "id" => "#{ctx.three.id}",
      "before" => "#{ctx.one.id}"
    })

    assert texts(ctx.card) == ~w(charlie alpha bravo)

    html =
      render_hook(card_panel(view), "move_check", %{"id" => "#{ctx.three.id}", "before" => nil})

    assert texts(ctx.card) == ~w(alpha bravo charlie)

    # The panel redraws in the new order.
    assert html =~ ~r/alpha.*bravo.*charlie/s
  end

  test "another card's item is left alone", ctx do
    other = card_fixture(ctx.col, %{"title" => "Other"})
    {:ok, theirs} = Boards.Checklists.add_checklist_item(other, "theirs")
    {:ok, _} = Boards.Checklists.add_checklist_item(other, "second")
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    render_hook(card_panel(view), "move_check", %{"id" => "#{theirs.id}", "before" => nil})

    render_hook(card_panel(view), "move_check", %{
      "id" => "#{ctx.one.id}",
      "before" => "#{theirs.id}"
    })

    assert texts(other) == ~w(theirs second)
    assert texts(ctx.card) == ~w(alpha bravo charlie)
  end

  test "a reader sees no handle and can't reorder", ctx do
    owner = user_fixture("order-owner@example.com")
    shared = board_fixture(%{"name" => "Shared order"}, owner: owner)
    card = card_fixture(hd(shared.columns), %{"title" => "Theirs"})
    {:ok, a} = Boards.Checklists.add_checklist_item(card, "a")
    {:ok, _} = Boards.Checklists.add_checklist_item(card, "b")
    {:ok, _} = Access.grant(shared, ctx.user, "read", owner)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{shared}/cards/#{card.id}")
    assert has_element?(view, ~s(ul#checklist-items[data-disabled="true"]))
    refute has_element?(view, ".check-handle")

    render_hook(card_panel(view), "move_check", %{"id" => "#{a.id}", "before" => nil})
    assert texts(card) == ~w(a b)
  end

  test "a placed page's panel reorders the page's items", ctx do
    page = page_fixture(ctx.board, %{"title" => "Placed"}, user: ctx.user)
    {:ok, _} = Slipdock.Wiki.place(page, ctx.col)
    {:ok, x} = Boards.Checklists.add_checklist_item(page, "x")
    {:ok, y} = Boards.Checklists.add_checklist_item(page, "y")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?#{[page: page.id]}")
    assert has_element?(view, ~s(ul#checklist-items-page-#{page.id}[phx-hook="Sortable"]))

    view
    |> with_target("#board-page")
    |> render_hook("move_check", %{"id" => "#{y.id}", "before" => "#{x.id}"})

    assert texts(page) == ~w(y x)
  end

  test "the page's own view reorders its items, and not a card's", ctx do
    page = page_fixture(ctx.board, %{"title" => "Own view"}, user: ctx.user)
    {:ok, x} = Boards.Checklists.add_checklist_item(page, "x")
    {:ok, y} = Boards.Checklists.add_checklist_item(page, "y")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{page.slug}")
    render_hook(view, "move_check", %{"id" => "#{y.id}", "before" => "#{x.id}"})
    assert texts(page) == ~w(y x)

    render_hook(view, "move_check", %{"id" => "#{ctx.one.id}", "before" => nil})
    assert texts(ctx.card) == ~w(alpha bravo charlie)
  end
end
