defmodule SlipdockWeb.DuplicateCardLiveTest do
  @moduledoc "Duplicate, in the card's Actions (W-1802): a copy after the original, opened."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Settings}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    column = hd(board.columns)
    card = card_fixture(column, %{"title" => "Pay rent", "flags" => ["waiting"]})
    {:ok, _} = Boards.add_checklist_item(card, "Transfer")
    next = card_fixture(column, %{"title" => "After"})
    %{board: board, column: column, card: card, next: next}
  end

  test "makes a copy straight after the original and opens it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    view |> element("#duplicate-card") |> render_click()

    ids = ctx.column.id |> Boards.active_items() |> Enum.map(fn {:card, id} -> id end)
    assert [card_id, copy_id, next_id] = ids
    assert card_id == ctx.card.id and next_id == ctx.next.id

    copy = Boards.get_card!(copy_id)
    assert copy.title == "Pay rent"
    assert copy.flags == []
    assert [%{text: "Transfer", done: false}] = copy.checklist_items

    assert_patch(view, ~p"/boards/#{ctx.board}/cards/#{copy_id}?#{%{}}")
    assert render(view) =~ "Duplicated as ##{copy_id}."
  end

  test "a reader's Duplicate is refused", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)
    conn = log_in_user(build_conn(), reader)
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    # The Actions are in a disabled fieldset for a reader; a click sent
    # anyway is refused on the server.
    view |> element("#duplicate-card") |> render_click()
    assert view |> element("#flash-error") |> render() =~ "read-only"

    assert length(Boards.active_items(ctx.column.id)) == 2
  end

  test "the card limit is said, not crashed on", ctx do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 2})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    view |> element("#duplicate-card") |> render_click()

    assert length(Boards.active_items(ctx.column.id)) == 2
    assert view |> element("#flash-error") |> render() =~ "has used all 2 of their cards"
  end
end
