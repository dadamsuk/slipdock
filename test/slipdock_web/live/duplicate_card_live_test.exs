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
    {:ok, _} = Boards.Checklists.add_checklist_item(card, "Transfer")
    next = card_fixture(column, %{"title" => "After"})
    %{board: board, column: column, card: card, next: next}
  end

  test "makes a copy straight after the original and opens it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    view |> element("#duplicate-card") |> render_click()

    ids = ctx.column.id |> Boards.Columns.active_items() |> Enum.map(fn {:card, id} -> id end)
    assert [card_id, copy_id, next_id] = ids
    assert card_id == ctx.card.id and next_id == ctx.next.id

    copy = Boards.Cards.get_card!(copy_id)
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

    # A reader's toolbar has no ⋯ (#1725); the event sent anyway is
    # refused on the server.
    refute has_element?(view, "#duplicate-card")
    view |> with_target("#board-card") |> render_click("duplicate_card", %{})

    assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
             "read-only"

    assert length(Boards.Columns.active_items(ctx.column.id)) == 2
  end

  describe "write on the card alone" do
    for board_level <- [nil, "read", "comment"] do
      @board_level board_level
      test "a card writer with #{board_level || "no"} board access is refused, and no card is made",
           ctx do
        writer = user_fixture("card-writer@example.com")

        grant_board(ctx, writer, @board_level)

        {:ok, _} = Access.grant(ctx.card, writer, "write", ctx.user)
        conn = log_in_user(build_conn(), writer)
        {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

        # They may edit the card, but Duplicate adds one to the board: it
        # isn't offered, and the event sent anyway is refused.
        assert has_element?(view, "#card-more")
        refute has_element?(view, "#duplicate-card")

        before = Boards.Columns.active_items(ctx.column.id)
        view |> with_target("#board-card") |> render_click("duplicate_card", %{})
        view |> with_target("#board-card") |> render_click("duplicate_card", %{})

        assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
                 "needs write access to the board"

        assert Boards.Columns.active_items(ctx.column.id) == before
        assert length(before) == 2
      end
    end
  end

  test "board write lowered while the card is open is asked again, and no card is made", ctx do
    writer = user_fixture("was-writer@example.com")
    {:ok, _} = Access.grant(ctx.board, writer, "write", ctx.user)
    {:ok, _} = Access.grant(ctx.card, writer, "write", ctx.user)
    conn = log_in_user(build_conn(), writer)
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    assert has_element?(view, "#duplicate-card")

    {:ok, _} = Access.grant(ctx.board, writer, "read", ctx.user)

    before = Boards.Columns.active_items(ctx.column.id)
    view |> with_target("#board-card") |> render_click("duplicate_card", %{})

    assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
             "needs write access to the board"

    assert Boards.Columns.active_items(ctx.column.id) == before
  end

  test "the card limit is said, not crashed on", ctx do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 2})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    view |> element("#duplicate-card") |> render_click()

    assert length(Boards.Columns.active_items(ctx.column.id)) == 2

    assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
             "has used all 2 of their cards"
  end

  defp grant_board(_ctx, _user, nil), do: :ok

  defp grant_board(ctx, user, level) do
    {:ok, _} = Access.grant(ctx.board, user, level, ctx.user)
    :ok
  end
end
