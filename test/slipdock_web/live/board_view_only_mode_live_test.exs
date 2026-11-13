defmodule SlipdockWeb.BoardViewOnlyModeLiveTest do
  @moduledoc """
  A user granted only a saved view sees the board through that view: in the
  mode it was saved in, and only the cards it shows, whichever mode the
  address asks for (#2770).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.BoardLive.State

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Filtered"}, owner: owner)
    column = hd(board.columns)
    shown = card_fixture(column, %{"title" => "Alpha shown"})
    hidden = card_fixture(column, %{"title" => "Beta hidden"})
    %{board: board, owner: owner, shown: shown, hidden: hidden}
  end

  defp share(ctx, mode) do
    viewer = user_fixture("viewer#{System.unique_integer([:positive])}@example.com")
    config = %{Config.defaults(mode) | q: "alpha"} |> Config.to_map()

    {:ok, saved} =
      Boards.SavedViews.create_saved_view(ctx.board, %{"name" => "Alpha", "config" => config})

    {:ok, _} = Access.grant(saved, viewer, "read", ctx.owner)
    assert Access.board_permission(viewer, ctx.board) == :view
    {log_in_user(build_conn(), viewer), saved}
  end

  defp refute_hidden(html, view, ctx) do
    refute html =~ "Beta hidden"
    refute render(view) =~ "Beta hidden"
    refute has_element?(view, "#card-#{ctx.hidden.id}")
    assert render(view) =~ "Alpha shown"
  end

  test "a board-mode view opened at its address shows only its cards", ctx do
    {conn, saved} = share(ctx, "board")
    path = ~p"/boards/#{ctx.board}?view=#{saved.id}"

    refute html_response(get(conn, path), 200) =~ "Beta hidden"
    {:ok, view, html} = live(conn, path)
    refute_hidden(html, view, ctx)
  end

  test "changes the address makes to a board-mode view don't widen it", ctx do
    {conn, saved} = share(ctx, "board")
    own = ~p"/boards/#{ctx.board}?view=#{saved.id}"
    path = own <> "&q=beta"

    assert redirected_to(get(conn, path)) == own
    {view, html} = open(conn, path)
    refute_hidden(html, view, ctx)
  end

  test "the board's address with no view goes to the view granted", ctx do
    {conn, saved} = share(ctx, "board")
    own = ~p"/boards/#{ctx.board}?view=#{saved.id}"

    assert redirected_to(get(conn, ~p"/boards/#{ctx.board}")) == own
    {view, html} = open(conn, ~p"/boards/#{ctx.board}")
    refute_hidden(html, view, ctx)
  end

  test "a list's snoozed cards are kept to the view too", ctx do
    {:ok, _} = Slipdock.Snooze.snooze(ctx.hidden, ctx.owner, "next week")

    {:ok, asleep} =
      Slipdock.Snooze.snooze(
        card_fixture(hd(ctx.board.columns), %{"title" => "Alpha asleep"}),
        ctx.owner,
        "next week"
      )

    {conn, saved} = share(ctx, "board")
    col = hd(ctx.board.columns).id
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}?view=#{saved.id}")

    %{socket: socket} = :sys.get_state(view.pid)

    assert [["Alpha asleep"]] =
             for(
               c <- socket.assigns.columns,
               c.column.id == col,
               do: Enum.map(c.snoozed, & &1.title)
             )

    assert has_element?(view, "#snoozed-#{col}", "1 snoozed")
    view |> element("#snoozed-#{col}") |> render_click()
    assert has_element?(view, "#snoozed-cards-#{col} #snoozed-card-#{asleep.id}")
    refute has_element?(view, "#snoozed-card-#{ctx.hidden.id}")
    refute render(view) =~ "Beta hidden"
  end

  # The live view at `path`, after any redirect or patch its mount makes.
  defp open(conn, path) do
    case live(conn, path) do
      {:ok, view, html} -> {view, html}
      {:error, {:live_redirect, %{to: to}}} -> open(conn, to)
    end
  end

  for {mode, route} <- [{"swimlanes", "swimlanes"}, {"table", "table"}] do
    test "a #{mode} view opened in board mode goes to its own mode, showing only its cards",
         ctx do
      {conn, saved} = share(ctx, unquote(mode))
      path = ~p"/boards/#{ctx.board}?view=#{saved.id}"
      own = "/boards/#{ctx.board.id}/#{unquote(route)}?view=#{saved.id}"

      assert redirected_to(get(conn, path)) == own
      assert {:error, {:live_redirect, %{to: ^own}}} = live(conn, path)

      {:ok, view, html} = live(conn, own)
      refute_hidden(html, view, ctx)
    end
  end

  describe "State.assign_columns/1 for a view-only reader" do
    # The lists drawn from the open view's own socket, with `change` made to
    # its assigns first: states the address never settles in, since the
    # view sends it to the granted view before anything is drawn.
    defp titles(view, change) do
      %{socket: socket} = :sys.get_state(view.pid)
      socket = %{socket | assigns: Map.merge(socket.assigns, change)}

      for col <- State.assign_columns(socket).assigns.columns,
          card <- col.cards,
          do: card.title
    end

    setup ctx do
      {conn, saved} = share(ctx, "board")
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}?view=#{saved.id}")
      %{view: view}
    end

    test "the view's saved settings decide, not the address's changes", ctx do
      %{socket: socket} = :sys.get_state(ctx.view.pid)
      widened = %{socket.assigns.swim | q: ""}

      assert titles(ctx.view, %{}) == ["Alpha shown"]
      assert titles(ctx.view, %{swim: widened}) == ["Alpha shown"]
    end

    test "with no view loaded, or one not granted, no card is drawn", ctx do
      {:ok, other} = Boards.SavedViews.create_saved_view(ctx.board, %{"name" => "Other"})

      assert titles(ctx.view, %{swim_view: nil, swim_base: %Config{}}) == []
      assert titles(ctx.view, %{swim_view: other, swim_base: %Config{}}) == []
    end
  end
end
