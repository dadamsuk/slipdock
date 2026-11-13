defmodule SlipdockWeb.BoardGrantLoweredLiveTest do
  @moduledoc """
  The board's own events, sent after their reader's grant is lowered, store
  nothing (#2981).

  `BoardLive.Show` gates its write and owner events on what the reader may
  do, and reads that again before each (`State.refresh_access/1`), as the
  panels in `PanelGrantLoweredLiveTest` (#2771) and the list settings in
  `ColumnGrantLoweredLiveTest` (#2946) do. Each test opens a board, lowers
  the grant, and sends the board's events.

  The grant is lowered two ways. `:told` is `Access.grant/4` (or
  `Access.revoke/1`), which tells the board. `:untold` changes the grant's
  row and tells nobody: it stands for a lowering the open board never hears
  of (a group's membership, a grant on the card a sub-board hangs from) and
  for an event that arrives before the board has taken the news in.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.{Card, Column, SavedView}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Lowered"}, owner: owner)
    writer = user_fixture("writer@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)

    %{board: board, owner: owner, writer: writer}
  end

  defp as(user), do: log_in_user(build_conn(), user)

  defp grants(ctx),
    do: from(g in Grant, where: g.board_id == ^ctx.board.id and g.user_id == ^ctx.writer.id)

  defp lower(:told, ctx) do
    {:ok, _} = Access.grant(ctx.board, ctx.writer, "read", ctx.owner)
    assert Access.board_permission(ctx.writer, ctx.board) == :read
  end

  defp lower(:untold, ctx) do
    assert {1, _} = Repo.update_all(grants(ctx), set: [level: "read"])
    assert Access.board_permission(ctx.writer, ctx.board) == :read
  end

  defp remove(:told, ctx) do
    {:ok, _} = Access.revoke(Repo.one!(grants(ctx)))
    assert Access.board_permission(ctx.writer, ctx.board) == :none
  end

  defp remove(:untold, ctx) do
    assert {1, _} = Repo.delete_all(grants(ctx))
    assert Access.board_permission(ctx.writer, ctx.board) == :none
  end

  defp columns(board),
    do: Repo.all(from(c in Column, where: c.board_id == ^board.id, order_by: c.id))

  defp cards(board),
    do: Repo.all(from(c in Card, where: c.board_id == ^board.id, order_by: c.id))

  defp views(board), do: Repo.all(from(v in SavedView, where: v.board_id == ^board.id))

  # Owning a board is `boards.owner_id`: handed to another account, the
  # one who opened it keeps only the write grant given here.
  defp hand_over(how, ctx) do
    {:ok, _} = Access.grant(ctx.board, ctx.owner, "write", ctx.owner)

    assert {1, _} =
             Repo.update_all(from(b in Boards.Board, where: b.id == ^ctx.board.id),
               set: [owner_id: ctx.writer.id]
             )

    if how == :told, do: Boards.PubSub.broadcast(ctx.board.id)
    assert Access.board_permission(ctx.owner, Boards.get_board!(ctx.board.id)) == :write
  end

  @read_only "You have read-only access to this board."

  for how <- [:told, :untold] do
    describe "the grant lowered to read, the board #{how}:" do
      test "the board's list events store nothing", ctx do
        [first, second | _] = lists = columns(ctx.board)
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")

        lower(unquote(how), ctx)

        assert render_hook(view, "rename_column", %{
                 "column_id" => "#{first.id}",
                 "name" => "Renamed"
               }) =~ @read_only

        assert render_hook(view, "add_column", %{"name" => "Another"}) =~ @read_only

        assert render_hook(view, "move_column", %{
                 "id" => "#{second.id}",
                 "before" => "#{first.id}"
               }) =~ @read_only

        assert columns(ctx.board) == lists
      end

      test "the board's card events store nothing", ctx do
        [first, second | _] = columns(ctx.board)
        card = card_fixture(first, %{"title" => "Stays put"})
        before = cards(ctx.board)
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")

        lower(unquote(how), ctx)

        assert render_hook(view, "quick_add_card", %{
                 "title" => "Not added",
                 "column_id" => "#{first.id}"
               }) =~ @read_only

        assert render_hook(view, "move_card", %{
                 "id" => "#{card.id}",
                 "to" => "#{second.id}",
                 "from" => "#{first.id}"
               }) =~ @read_only

        assert render_hook(view, "swim_save_view", %{"name" => "Mine"}) =~ @read_only

        assert cards(ctx.board) == before
        assert views(ctx.board) == []
      end

      test "the board is redrawn for a reader", ctx do
        [first | _] = columns(ctx.board)
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")
        assert has_element?(view, "#board-column")

        lower(unquote(how), ctx)
        render_hook(view, "rename_column", %{"column_id" => "#{first.id}", "name" => "Renamed"})

        # A reader gets no list settings to push to (`:if={@can_write}`).
        refute has_element?(view, "#board-column")
      end
    end

    describe "the grant removed, the board #{how}:" do
      test "a write event stores nothing and the reader is sent away", ctx do
        # The view stops when it sends its reader away.
        Process.flag(:trap_exit, true)
        [first | _] = lists = columns(ctx.board)
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")

        remove(unquote(how), ctx)

        # Told, the board sends its reader away as the news arrives, and the
        # view is gone by the time the event is sent; untold, the event's
        # own read of the level sends them.
        if unquote(how) == :told, do: assert_redirect(view, ~p"/")

        try do
          render_hook(view, "rename_column", %{"column_id" => "#{first.id}", "name" => "Renamed"})
        catch
          :exit, _ -> :ok
        end

        if unquote(how) == :untold, do: assert_redirect(view, ~p"/")
        assert columns(ctx.board) == lists
      end
    end

    describe "the board's owner no longer its owner, the board #{how}:" do
      setup ctx do
        {:ok, saved} =
          Boards.SavedViews.create_saved_view(ctx.board, %{
            "name" => "Shared",
            "config" => %{"mode" => "swimlanes"}
          })

        %{saved: saved}
      end

      test "the owner's events store nothing", ctx do
        {:ok, view, _} =
          live(as(ctx.owner), ~p"/boards/#{ctx.board}/swimlanes?view=#{ctx.saved.id}")

        hand_over(unquote(how), ctx)

        assert render_hook(view, "swim_publish_view", %{}) =~
                 "Only the board&#39;s owner can do that."

        refute Repo.get!(SavedView, ctx.saved.id).public_token
      end

      # Sharing a view is the owner's too, checked by `share_target/2`; sent
      # first, so nothing before it has read the level again.
      test "the open view is shared with nobody", ctx do
        {:ok, view, _} =
          live(as(ctx.owner), ~p"/boards/#{ctx.board}/swimlanes?view=#{ctx.saved.id}")

        hand_over(unquote(how), ctx)

        assert render_hook(view, "share", %{
                 "resource" => "view",
                 "level" => "read",
                 "email" => ctx.writer.email
               }) =~ "You can&#39;t share that."

        assert Access.list_grants(ctx.saved) == []
      end
    end
  end

  # The redraw after a moved level patches the address when the loaded view
  # has gone; a reader already being sent away gets no patch on top.
  test "the grant and the open view both gone untold: the reader is sent away", ctx do
    Process.flag(:trap_exit, true)
    [first | _] = lists = columns(ctx.board)

    {:ok, saved} =
      Boards.SavedViews.create_saved_view(ctx.board, %{
        "name" => "Gone",
        "config" => %{"mode" => "swimlanes"}
      })

    {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/swimlanes?view=#{saved.id}")

    remove(:untold, ctx)
    assert {1, _} = Repo.delete_all(from(v in SavedView, where: v.id == ^saved.id))

    try do
      render_hook(view, "rename_column", %{"column_id" => "#{first.id}", "name" => "Renamed"})
    catch
      :exit, _ -> :ok
    end

    assert_redirect(view, ~p"/")
    assert columns(ctx.board) == lists
  end

  test "a writer whose grant is unchanged still renames the list", ctx do
    [first | _] = columns(ctx.board)
    {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")

    refute render_hook(view, "rename_column", %{
             "column_id" => "#{first.id}",
             "name" => "Renamed"
           }) =~ @read_only

    assert Repo.get!(Column, first.id).name == "Renamed"
  end

  test "an owner who is still the owner publishes and shares a view", ctx do
    {:ok, saved} =
      Boards.SavedViews.create_saved_view(ctx.board, %{
        "name" => "Shared",
        "config" => %{"mode" => "swimlanes"}
      })

    {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}/swimlanes?view=#{saved.id}")
    render_hook(view, "swim_publish_view", %{})
    assert Repo.get!(SavedView, saved.id).public_token

    render_hook(view, "share", %{
      "resource" => "view",
      "level" => "read",
      "email" => ctx.writer.email
    })

    assert [%{user_id: id}] = Access.list_grants(saved)
    assert id == ctx.writer.id
  end
end
