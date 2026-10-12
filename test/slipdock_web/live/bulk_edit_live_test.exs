defmodule SlipdockWeb.BulkEditLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards.Card
  alias Slipdock.Repo

  setup do
    board = board_fixture(%{"name" => "Plan"})
    [backlog, todo | _] = board.columns
    a = card_fixture(todo, %{"title" => "Alpha"})
    b = card_fixture(todo, %{"title" => "Bravo"})
    c = card_fixture(todo, %{"title" => "Charlie"})
    %{board: board, backlog: backlog, todo: todo, a: a, b: b, c: c}
  end

  defp select_mode(view), do: view |> element("#select-mode-toggle") |> render_click()
  defp click_card(view, card), do: view |> element("#card-#{card.id}") |> render_click()

  test "clicking cards in select mode picks them out instead of opening them", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    refute has_element?(view, "#bulk-bar")

    select_mode(view)
    assert has_element?(view, "#bulk-bar")
    assert render(view) =~ "Click cards to select them"

    click_card(view, ctx.a)
    click_card(view, ctx.b)
    assert has_element?(view, "#card-#{ctx.a.id}[data-selected]")
    assert has_element?(view, "#bulk-count", "2 selected")
    # Nothing opened.
    refute render(view) =~ "card-panel"
    refute_patched(view)

    # A second click lets go of it.
    click_card(view, ctx.b)
    assert has_element?(view, "#bulk-count", "1 selected")

    view |> element("#bulk-clear") |> render_click()
    assert has_element?(view, "#bulk-count", "Click cards to select them")

    view |> element("#bulk-done") |> render_click()
    refute has_element?(view, "#bulk-bar")

    # Out of select mode, a click opens the card again.
    click_card(view, ctx.a)
    assert_patched(view, ~p"/boards/#{ctx.board}/cards/#{ctx.a}")
  end

  test "archives the selection", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    select_mode(view)
    click_card(view, ctx.a)
    click_card(view, ctx.c)

    view |> element("#bulk-archive") |> render_click()

    assert render(view) =~ "Archived 2 cards."
    assert Repo.get(Card, ctx.a.id).archived_at
    assert Repo.get(Card, ctx.c.id).archived_at
    refute Repo.get(Card, ctx.b.id).archived_at
    refute has_element?(view, "#card-#{ctx.a.id}")
    # Still selecting, with nothing picked out.
    assert has_element?(view, "#bulk-count", "Click cards to select them")
  end

  test "deletes, asking first", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    select_mode(view)
    click_card(view, ctx.b)

    assert has_element?(view, "#bulk-delete[data-confirm]")
    view |> element("#bulk-delete") |> render_click()

    assert render(view) =~ "Deleted 1 card."
    assert is_nil(Repo.get(Card, ctx.b.id))
  end

  test "tags and sets priority from the Set menu", ctx do
    tag = tag_fixture(ctx.board, "ops")
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    select_mode(view)
    click_card(view, ctx.a)
    click_card(view, ctx.b)

    view |> form("#bulk-set", %{"action" => "tag:#{tag.id}"}) |> render_change()
    assert render(view) =~ "Tagged 2 cards."
    assert [%{name: "ops"}] = Repo.preload(Repo.get(Card, ctx.a.id), :tags).tags

    click_card(view, ctx.c)
    view |> form("#bulk-set", %{"action" => "priority:critical"}) |> render_change()
    assert Repo.get(Card, ctx.c.id).priority == "critical"
    assert Repo.get(Card, ctx.a.id).priority == "none"
  end

  test "moves to another list, and to another board's list", ctx do
    other = board_fixture(%{"name" => "Errands"}, owner: user_fixture())
    dest = hd(other.columns)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    select_mode(view)
    click_card(view, ctx.a)
    # Both boards' lists are offered.
    assert has_element?(
             view,
             ~s(#bulk-move optgroup[label="Plan"] option[value="move:#{ctx.backlog.id}"])
           )

    assert has_element?(
             view,
             ~s(#bulk-move optgroup[label="Errands"] option[value="move:#{dest.id}"])
           )

    view |> form("#bulk-move", %{"action" => "move:#{ctx.backlog.id}"}) |> render_change()
    assert render(view) =~ "Moved 1 card."
    assert Repo.get(Card, ctx.a.id).column_id == ctx.backlog.id

    click_card(view, ctx.b)
    view |> form("#bulk-move", %{"action" => "move:#{dest.id}"}) |> render_change()
    assert Repo.get(Card, ctx.b.id).board_id == other.id
    refute has_element?(view, "#card-#{ctx.b.id}")
  end

  test "the empty menu choice does nothing", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    select_mode(view)
    click_card(view, ctx.a)
    view |> form("#bulk-set", %{"action" => ""}) |> render_change()
    assert has_element?(view, "#bulk-count", "1 selected")
  end

  test "a card id from somewhere else is never selected or changed", ctx do
    elsewhere = card_fixture(hd(board_fixture(%{}, owner: user_fixture("x@example.com")).columns))
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    select_mode(view)

    render_click(view, "open_card", %{"id" => to_string(elsewhere.id)})
    assert has_element?(view, "#bulk-count", "Click cards to select them")

    render_click(view, "bulk_apply", %{"action" => "delete"})
    assert Repo.get(Card, elsewhere.id)
  end

  test "a read-only reader gets no Select button and can't apply", ctx do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns))
    share_fixture(board, ctx.user, "read")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{board}")
    refute has_element?(view, "#select-mode-toggle")

    assert render_click(view, "toggle_select_mode", %{}) =~ "read-only"
    refute has_element?(view, "#bulk-bar")
    assert render_click(view, "bulk_apply", %{"action" => "archive"}) =~ "read-only"
    refute Repo.get(Card, card.id).archived_at
  end
end
