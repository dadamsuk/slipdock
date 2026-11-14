defmodule SlipdockWeb.BoardLiveResyncTest do
  @moduledoc """
  A board page that missed a change catches up when it asks (#2918).

  The page asks with `resync` (`assets/js/board_resync.js`): when its tab
  comes back into view and once a minute while in view. Each test changes
  the board's rows behind the page's back, with `Repo.update_all`, which
  broadcasts nothing: it stands for a broadcast that never arrived.
  """
  use SlipdockWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Boards.PubSub
  alias Slipdock.Repo

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Resync"}, owner: owner)
    [todo, done | _] = Enum.sort_by(board.columns, & &1.position)
    card = card_fixture(todo, %{"title" => "Moved behind its back"})
    %{board: board, todo: todo, done: done, card: card}
  end

  defp open(conn, board) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    view
  end

  defp in_column?(view, column, card),
    do: has_element?(view, "#column-#{column.id} [id$='card-#{card.id}']")

  test "a card moved without a broadcast shows where it is after a resync", ctx do
    view = open(ctx.conn, ctx.board)
    assert in_column?(view, ctx.todo, ctx.card)

    Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id), set: [column_id: ctx.done.id])
    assert in_column?(view, ctx.todo, ctx.card), "nothing told the page"

    log =
      capture_log(fn ->
        render_hook(view, "resync", %{})
        assert_reply(view, %{resynced: true})
      end)

    assert in_column?(view, ctx.done, ctx.card)
    refute in_column?(view, ctx.todo, ctx.card)
    assert log =~ "Board page #{ctx.board.id} missed a change"
  end

  test "a reorder, which leaves updated_at alone, is caught too", ctx do
    other = card_fixture(ctx.todo, %{"title" => "Second"})
    view = open(ctx.conn, ctx.board)

    Repo.update_all(from(c in Card, where: c.id == ^other.id), set: [position: -1])
    render_hook(view, "resync", %{})
    assert_reply(view, %{resynced: true})
  end

  test "a list renamed without a broadcast is caught", ctx do
    view = open(ctx.conn, ctx.board)

    Repo.update_all(from(c in Column, where: c.id == ^ctx.todo.id), set: [name: "Renamed"])
    render_hook(view, "resync", %{})
    assert_reply(view, %{resynced: true})
    assert render(view) =~ "Renamed"
  end

  test "the board renamed without a broadcast is caught", ctx do
    view = open(ctx.conn, ctx.board)

    Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [name: "Renamed board"])
    render_hook(view, "resync", %{})
    assert_reply(view, %{resynced: true})
  end

  test "nothing changed: nothing is drawn again, and nothing is logged", ctx do
    view = open(ctx.conn, ctx.board)

    log =
      capture_log(fn ->
        render_hook(view, "resync", %{})
        assert_reply(view, %{resynced: false})
      end)

    refute log =~ "missed a change"
  end

  test "a change the page was told of leaves nothing for the resync to find", ctx do
    view = open(ctx.conn, ctx.board)

    {:ok, _} = Slipdock.Boards.Cards.update_card(ctx.card, %{"title" => "Told"})
    assert render(view) =~ "Told"

    render_hook(view, "resync", %{})
    assert_reply(view, %{resynced: false})
  end

  test "a reader with read access can ask too", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Slipdock.Access.grant(ctx.board, reader, "read", ctx.user)
    view = open(log_in_user(build_conn(), reader), ctx.board)

    Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id), set: [column_id: ctx.done.id])
    render_hook(view, "resync", %{})
    assert_reply(view, %{resynced: true})
    assert in_column?(view, ctx.done, ctx.card)
  end

  test "the page carries the hook that asks, with its notice hidden", ctx do
    view = open(ctx.conn, ctx.board)
    assert has_element?(view, "#board-resync[phx-hook=BoardResync][phx-update=ignore]")
    assert has_element?(view, "#board-stale[hidden]", "may be out of date")
  end

  describe "fingerprint/1" do
    test "moves with a card's list, place, completion, archiving and edits", ctx do
      base = PubSub.fingerprint(ctx.board.id)
      q = from(c in Card, where: c.id == ^ctx.card.id)

      for change <- [
            [column_id: ctx.done.id],
            [position: 99],
            [completed: true],
            [archived_at: ~U[2026-11-12 21:00:00Z]],
            [updated_at: ~U[2030-01-01 00:00:00Z]],
            [title: "Renamed in the same second"]
          ] do
        Repo.transaction(fn ->
          Repo.update_all(q, set: change)
          refute PubSub.fingerprint(ctx.board.id) == base, inspect(change)
          Repo.rollback(:undo)
        end)
      end

      assert PubSub.fingerprint(ctx.board.id) == base
    end

    test "moves with a card added and with a list's name and place", ctx do
      base = PubSub.fingerprint(ctx.board.id)
      card_fixture(ctx.done)
      after_add = PubSub.fingerprint(ctx.board.id)
      refute after_add == base

      Repo.update_all(from(c in Column, where: c.id == ^ctx.done.id), set: [position: 50])
      refute PubSub.fingerprint(ctx.board.id) == after_add
    end

    test "moves with the board's own row: its name and when it last changed", ctx do
      base = PubSub.fingerprint(ctx.board.id)
      q = from(b in Board, where: b.id == ^ctx.board.id)

      for change <- [[name: "Renamed board"], [updated_at: ~U[2030-01-01 00:00:00Z]]] do
        Repo.transaction(fn ->
          Repo.update_all(q, set: change)
          refute PubSub.fingerprint(ctx.board.id) == base, inspect(change)
          Repo.rollback(:undo)
        end)
      end

      assert PubSub.fingerprint(ctx.board.id) == base
    end

    test "a card on another board doesn't move it", ctx do
      base = PubSub.fingerprint(ctx.board.id)
      other = board_fixture(%{}, owner: ctx.user)
      card_fixture(hd(other.columns))
      assert PubSub.fingerprint(ctx.board.id) == base
    end
  end
end
