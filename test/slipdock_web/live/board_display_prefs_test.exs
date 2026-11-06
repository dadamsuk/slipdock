defmodule SlipdockWeb.BoardDisplayPrefsTest do
  @moduledoc """
  A board's Display options remembered in the browser (#1879): the push
  that tells the `DisplayPrefs` hook what is in use, and the restore that
  puts back what it remembered when the reader returns to a bare URL.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}
  alias Slipdock.Swimlanes.Config

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card_fixture(hd(board.columns), %{"title" => "A card"})
    %{board: board}
  end

  defp key(board, mode), do: "display:#{board.id}:#{mode}"

  describe "the push" do
    test "a bare board URL asks the browser to restore", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      key = key(board, :board)
      assert_push_event(view, "display-prefs", %{key: ^key, query: query, restore: true})
      assert query == %{}
      assert has_element?(view, "#display-prefs[phx-hook=DisplayPrefs]")
    end

    test "a URL naming display options is remembered, not restored over", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?density=compact&q=card")
      key = key(ctx.board, :board)

      assert_push_event(view, "display-prefs", %{key: ^key, query: query, restore: false})
      # Filters are not part of what is remembered.
      assert query == %{"density" => "compact"}
    end

    test "a change in the Display menu is pushed to remember, never to restore", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert_push_event(view, "display-prefs", %{restore: true})

      render_click(view, "swim_set", %{"key" => "width", "value" => "wide"})
      assert_push_event(view, "display-prefs", %{query: %{"width" => "wide"}, restore: false})

      # Back to the defaults is remembered too, as an empty set, not restored over.
      render_click(view, "swim_set", %{"key" => "width", "value" => "normal"})
      assert_push_event(view, "display-prefs", %{query: query, restore: false})
      assert query == %{}
    end

    test "each mode is keyed on its own, and restores on its first visit", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert_push_event(view, "display-prefs", %{restore: true})

      render_patch(view, ~p"/boards/#{ctx.board}/table")
      key = key(ctx.board, :table)
      assert_push_event(view, "display-prefs", %{key: ^key, restore: true})
    end

    test "a saved view is left alone", ctx do
      {:ok, saved} =
        Boards.create_saved_view(ctx.board, %{
          "name" => "Compact",
          "config" => Config.to_map(%{Config.defaults("board") | density: "compact"})
        })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?view=#{saved.id}")
      refute_push_event(view, "display-prefs", %{})
    end

    test "a view-only reader's page is left alone", ctx do
      other = user_fixture()

      {:ok, saved} =
        Boards.create_saved_view(ctx.board, %{
          "name" => "Shared",
          "config" => Config.to_map(Config.defaults("board"))
        })

      {:ok, _} = Access.grant(saved, other, "read", ctx.user)
      conn = log_in_user(build_conn(), other)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}?view=#{saved.id}")
      refute_push_event(view, "display-prefs", %{})
    end
  end

  describe "display_restore" do
    test "puts what was remembered into the URL in place", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?q=card")
      assert_push_event(view, "display-prefs", %{restore: true})

      render_hook(view, "display_restore", %{
        "query" => %{"density" => "compact", "show_compact" => "tags,id", "q" => "ignored"}
      })

      assert_patch(view, ~p"/boards/#{ctx.board}?density=compact&q=card&show_compact=tags%2Cid")
      assert_push_event(view, "display-prefs", %{query: query, restore: false})
      assert query == %{"density" => "compact", "show_compact" => "tags,id"}
    end

    test "junk, or nothing new, patches nothing", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert_push_event(view, "display-prefs", %{restore: true})

      render_hook(view, "display_restore", %{"query" => %{"density" => 7, "width" => "huge"}})
      render_hook(view, "display_restore", %{"query" => "density=compact"})
      render_hook(view, "display_restore", %{})
      refute_push_event(view, "display-prefs", %{})
      refute render(view) =~ "That isn&#39;t something this page can do"
    end

    test "is ignored on a saved view", ctx do
      {:ok, saved} = Boards.create_saved_view(ctx.board, %{"name" => "Plain"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?view=#{saved.id}")

      render_hook(view, "display_restore", %{"query" => %{"density" => "compact"}})
      refute_push_event(view, "display-prefs", %{})
      refute has_element?(view, "input[name=density][value=compact][checked]")
    end
  end
end
