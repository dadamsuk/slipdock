defmodule SlipdockWeb.BoardPanelAccessLiveTest do
  @moduledoc """
  The archive, tags and activity panels show the whole board, so they open
  only for a reader of it: access through one saved view or one card doesn't
  open them, and `BoardLive.ArchiveComponent` lists and searches nothing for
  anyone below read on the board (#2747).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}
  alias SlipdockWeb.BoardLive.ArchiveComponent
  alias Slipdock.Swimlanes.Config

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Panelled"}, owner: owner)
    column = hd(board.columns)
    card = card_fixture(column, %{"title" => "Shared card"})
    {:ok, gone} = Boards.Cards.archive_card(card_fixture(column, %{"title" => "Archived secret"}))

    %{board: board, card: card, gone: gone, owner: owner}
  end

  defp as(user), do: log_in_user(build_conn(), user)

  defp viewer(ctx) do
    viewer = user_fixture("viewer@example.com")

    {:ok, saved} =
      Boards.SavedViews.create_saved_view(ctx.board, %{
        "name" => "Everything",
        "config" => Config.to_map(Config.defaults("table"))
      })

    {:ok, _} = Access.grant(saved, viewer, "read", ctx.owner)
    assert Access.board_permission(viewer, ctx.board) == :view
    {viewer, saved}
  end

  defp refute_board_panels(view, ctx) do
    refute has_element?(view, "#board-archive")
    refute has_element?(view, "#board-tags")
    refute has_element?(view, "#board-activity")
    refute render(view) =~ "Archived secret"
    refute render(view) =~ "#{ctx.gone.id} · from"
  end

  test "a reader opens the archive and finds archived cards there", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

    {:ok, view, _} = live(as(reader), ~p"/boards/#{ctx.board}/archive")
    assert has_element?(view, "#archived-#{ctx.gone.id}", "Archived secret")

    view |> element("#archive-search") |> render_change(%{"q" => "secret"})
    assert has_element?(view, "#archived-#{ctx.gone.id}")
  end

  for panel <- ~w(archive tags activity) do
    test "a view-only user is refused the #{panel} panel", ctx do
      {viewer, saved} = viewer(ctx)

      back = ~p"/boards/#{ctx.board}/table?#{[view: saved.id]}"

      assert {:error, {:live_redirect, %{to: ^back, flash: flash}}} =
               live(
                 as(viewer),
                 "/boards/#{ctx.board.id}/table/#{unquote(panel)}?view=#{saved.id}"
               )

      assert flash["error"] == "That isn't part of the view shared with you."
    end
  end

  test "a view-only user patched to the archive stays off it", ctx do
    {viewer, saved} = viewer(ctx)
    {:ok, view, _} = live(as(viewer), ~p"/boards/#{ctx.board}/table?#{[view: saved.id]}")

    render_patch(view, ~p"/boards/#{ctx.board}/table/archive?#{[view: saved.id]}")
    refute_board_panels(view, ctx)
  end

  test "a view-only user opening an archived card isn't sent to the archive", ctx do
    {viewer, saved} = viewer(ctx)

    back = ~p"/boards/#{ctx.board}/table?#{[view: saved.id]}"

    assert {:error, {:live_redirect, %{to: ^back, flash: flash}}} =
             live(
               as(viewer),
               ~p"/boards/#{ctx.board}/table/cards/#{ctx.gone}?#{[view: saved.id]}"
             )

    assert flash["error"] == "That card no longer exists."
  end

  for panel <- ~w(archive tags activity) do
    test "a card-only guest patched from their card to the #{panel} panel is sent away", ctx do
      guest = user_fixture("guest@example.com")
      {:ok, _} = Access.grant(ctx.card, guest, "write", ctx.owner)
      assert Access.board_permission(guest, ctx.board) == :none

      {:ok, view, _} = live(as(guest), ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      assert has_element?(view, "#card-modal", "Shared card")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               render_patch(view, "/boards/#{ctx.board.id}/#{unquote(panel)}")
    end
  end

  # #2947: the board change that finds the reader's grant gone redirects them
  # with the flash; the open card panel isn't patched shut on top of that,
  # which raised and crashed the process before the redirect was sent.
  test "a reader whose grant goes while a card is open is sent away, not crashed", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, grant} = Access.grant(ctx.board, reader, "read", ctx.owner)

    {:ok, view, _} = live(as(reader), ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
    assert render(view) =~ "Shared card"

    {:ok, _} = Access.revoke(grant)
    {:ok, _} = Boards.Cards.update_card(ctx.card, %{"title" => "Renamed card"})
    send(view.pid, {:board_changed, ctx.board.id})

    assert {"/", %{"error" => "Your access to that board was removed."}} =
             assert_redirect(view)
  end

  describe "ArchiveComponent below read on the board" do
    test "lists nothing", ctx do
      {viewer, _saved} = viewer(ctx)

      html =
        render_component(ArchiveComponent,
          id: "archive",
          board: ctx.board,
          current_user: viewer,
          query: "",
          close_path: "/"
        )

      refute html =~ "Archived secret"
      assert html =~ "No archived cards."
    end

    test "searches nothing", ctx do
      {viewer, _saved} = viewer(ctx)

      # The panel asks what its reader may do at every event (#2771), so the
      # socket carries who is asking and about which board.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          board: ctx.board,
          current_user: viewer,
          reader?: true,
          can_write: true,
          query: "",
          archived: []
        }
      }

      assert {:noreply, socket} =
               ArchiveComponent.handle_event("filter_archived", %{"q" => "secret"}, socket)

      assert socket.assigns.archived == []
      assert socket.assigns.query == ""
      assert_received {:put_flash, :error, "You don't have access to this board's archive."}
    end
  end
end
