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

  # What a shift-click sends: `app.js`'s click metadata adds `shift`.
  defp shift_click(view, card),
    do: render_click(view, "open_card", %{"id" => to_string(card.id), "shift" => true})

  defp select_list(view, column),
    do: view |> element("#select-list-#{column.id}") |> render_click()

  defp selected?(view, card), do: has_element?(view, "#card-#{card.id}[data-selected]")

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

  describe "shift-click picks a run (#2690)" do
    test "within a list, from the last card clicked", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)
      assert render(view) =~ "Shift-click for a run"

      click_card(view, ctx.a)
      shift_click(view, ctx.c)
      assert has_element?(view, "#bulk-count", "3 selected")
      assert selected?(view, ctx.b)
    end

    test "down a list and across to the next, in the order the board shows", ctx do
      d = card_fixture(ctx.backlog, %{"title" => "Delta"})
      e = card_fixture(ctx.backlog, %{"title" => "Echo"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)

      click_card(view, e)
      shift_click(view, ctx.b)
      assert has_element?(view, "#bulk-count", "3 selected")
      assert selected?(view, e) and selected?(view, ctx.a) and selected?(view, ctx.b)
      refute selected?(view, d)
      refute selected?(view, ctx.c)
    end

    test "with no starting point it picks the one card", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)

      shift_click(view, ctx.c)
      assert has_element?(view, "#bulk-count", "1 selected")
      assert selected?(view, ctx.c)
    end

    test "a starting point the filters now hide picks the one card", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)
      click_card(view, ctx.a)

      render_hook(view, "search", %{"q" => "r"})
      refute has_element?(view, "#card-#{ctx.a.id}")

      shift_click(view, ctx.c)
      # Alpha stays picked; nothing between it and Charlie is added.
      assert has_element?(view, "#bulk-count", "2 selected")
      refute selected?(view, ctx.b)
    end

    test "Clear, Done and a bulk action each drop the starting point", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)

      click_card(view, ctx.a)
      view |> element("#bulk-clear") |> render_click()
      shift_click(view, ctx.c)
      assert has_element?(view, "#bulk-count", "1 selected")

      view |> element("#bulk-assign_me") |> render_click()
      shift_click(view, ctx.a)
      assert has_element?(view, "#bulk-count", "1 selected")

      view |> element("#bulk-done") |> render_click()
      select_mode(view)
      shift_click(view, ctx.c)
      assert has_element?(view, "#bulk-count", "1 selected")
      refute selected?(view, ctx.b)
    end

    test "Snooze… from the bar drops the starting point too", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)
      click_card(view, ctx.a)
      # Bravo, clicked twice: let go, but still where a run would start.
      click_card(view, ctx.b)
      click_card(view, ctx.b)

      view |> element("#bulk-snooze") |> render_click()
      view |> element("#snooze-month") |> render_click()
      assert render(view) =~ "Snoozed 1 card until"

      shift_click(view, ctx.c)
      assert has_element?(view, "#bulk-count", "1 selected")
      refute selected?(view, ctx.b)
    end

    test "a plain click after a run still toggles one card", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)
      click_card(view, ctx.a)
      shift_click(view, ctx.c)

      click_card(view, ctx.b)
      assert has_element?(view, "#bulk-count", "2 selected")
      refute selected?(view, ctx.b)
    end
  end

  describe "a list's select-all (#2690)" do
    test "selects every card in the list, then deselects them", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#select-list-#{ctx.todo.id}")

      select_mode(view)
      other = card_fixture(ctx.backlog, %{"title" => "Other"})
      click_card(view, other)

      select_list(view, ctx.todo)
      assert has_element?(view, "#bulk-count", "4 selected")
      assert has_element?(view, "#select-list-#{ctx.todo.id}[aria-pressed=true]")

      select_list(view, ctx.todo)
      assert has_element?(view, "#bulk-count", "1 selected")
      assert selected?(view, other)
      assert has_element?(view, "#select-list-#{ctx.todo.id}[aria-pressed=false]")
    end

    test "fills in a list partly selected", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)
      click_card(view, ctx.b)

      select_list(view, ctx.todo)
      assert has_element?(view, "#bulk-count", "3 selected")
    end

    test "leaves out cards the filters hide and stand-ins", ctx do
      real = card_fixture(ctx.backlog, %{"title" => "Real one"})

      # Its title matches the filter, so it is shown: only being a stand-in
      # keeps it out.
      stand_in =
        ctx.todo
        |> card_fixture(%{"title" => "Stand-in shown"})
        |> Ecto.Changeset.change(stand_in_for_id: real.id)
        |> Repo.update!()

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)
      render_hook(view, "search", %{"q" => "h"})
      refute has_element?(view, "#card-#{ctx.b.id}")
      assert has_element?(view, "#card-#{stand_in.id}")

      select_list(view, ctx.todo)
      # Alpha and Charlie: not Bravo (filtered out), nor the stand-in.
      assert has_element?(view, "#bulk-count", "2 selected")
      assert selected?(view, ctx.a) and selected?(view, ctx.c)
      refute selected?(view, stand_in)

      render_hook(view, "search", %{"q" => ""})
      refute selected?(view, ctx.b)
    end

    test "does nothing out of select mode", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      render_click(view, "select_list", %{"id" => to_string(ctx.todo.id)})
      refute has_element?(view, "#bulk-bar")
      refute selected?(view, ctx.a)

      # Nothing drawn shows a selection out of select mode, so a bulk action
      # is what would see one: it must find none to act on.
      render_click(view, "bulk_apply", %{"action" => "archive"})

      for card <- [ctx.a, ctx.b, ctx.c],
          do: refute(Repo.get(Card, card.id).archived_at)
    end
  end

  describe "Select all in a list's menu (#2702)" do
    defp select_all(view, column),
      do: view |> element("#select-all-list-#{column.id}") |> render_click()

    test "turns select mode on with every card in the list selected", ctx do
      other = card_fixture(ctx.backlog, %{"title" => "Other"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#bulk-bar")

      select_all(view, ctx.todo)
      assert has_element?(view, "#bulk-bar")
      assert has_element?(view, "#select-mode-toggle[aria-pressed=true]")
      assert has_element?(view, "#bulk-count", "3 selected")
      assert selected?(view, ctx.a) and selected?(view, ctx.b) and selected?(view, ctx.c)
      refute selected?(view, other)
      assert has_element?(view, "#select-list-#{ctx.todo.id}[aria-pressed=true]")

      # A bulk action then acts on them.
      render_click(view, "bulk_apply", %{"action" => "archive"})
      for card <- [ctx.a, ctx.b, ctx.c], do: assert(Repo.get(Card, card.id).archived_at)
      refute Repo.get(Card, other.id).archived_at
    end

    test "in select mode, adds the list and keeps what is picked", ctx do
      other = card_fixture(ctx.backlog, %{"title" => "Other"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_mode(view)
      click_card(view, other)

      select_all(view, ctx.todo)
      assert has_element?(view, "#bulk-count", "4 selected")
      assert selected?(view, other)

      # Chosen again it only selects: nothing is let go.
      select_all(view, ctx.todo)
      assert has_element?(view, "#bulk-count", "4 selected")
    end

    test "an empty list turns select mode on with nothing picked", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      select_all(view, ctx.backlog)
      assert has_element?(view, "#select-mode-toggle[aria-pressed=true]")
      refute selected?(view, ctx.a)
    end

    test "a read-only reader gets no item and is refused", ctx do
      owner = user_fixture("owner@example.com")
      board = board_fixture(%{}, owner: owner)
      [column | _] = board.columns
      card = card_fixture(column)
      share_fixture(board, ctx.user, "read")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{board}")
      assert has_element?(view, "#card-view-list-#{column.id}")
      refute has_element?(view, "#select-all-list-#{column.id}")

      assert render_click(view, "select_all_in_list", %{"id" => to_string(column.id)}) =~
               "read-only"

      refute has_element?(view, "#bulk-bar")
      refute selected?(view, card)
    end
  end
end
