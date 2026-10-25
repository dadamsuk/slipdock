defmodule SlipdockWeb.BoardSettingsTabsTest do
  @moduledoc """
  Board settings in tabs (#1291): one tab showing at a time, `?tab=` to open
  on one, and the board's form keeping what was typed across General and
  Features, since every tab is drawn and the others only hidden.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias SlipdockWeb.BoardLive.SettingsComponent

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Tabbed", "code" => "tabbed1291"}, owner: user)
    %{conn: conn, board: board}
  end

  defp keys, do: Enum.map(SettingsComponent.tabs(), &elem(&1, 0))

  # Only `key`'s panel shows, and only its tab is marked selected.
  defp assert_showing(view, key) do
    for other <- keys() do
      hidden? = has_element?(view, "#settings-panel-#{other}.hidden")
      selected? = has_element?(view, ~s|#settings-tab-#{other}[aria-selected="true"]|)

      if other == key do
        refute hidden?, "#{other} should show"
        assert selected?
      else
        assert hidden?, "#{other} should be hidden while #{key} shows"
        refute selected?
      end
    end
  end

  test "opens on General, with a tab for each panel", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

    assert keys() == ~w(general features planning deploys gardening sharing manage)
    for key <- keys(), do: assert(has_element?(view, "#settings-tab-#{key}"))
    assert_showing(view, "general")
  end

  test "each tab shows its own panel, and what lives there", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

    where = %{
      "general" => "#settings-panel-general #board_name",
      "features" => "#settings-panel-features #board-show-pulse",
      "planning" => "#settings-panel-planning #board-fields",
      "deploys" => "#settings-panel-deploys #deploy-setup-form",
      "gardening" => "#settings-panel-gardening #gardening-form",
      "sharing" => "#settings-panel-sharing",
      "manage" => ~s|#settings-panel-manage button[phx-click="delete_board"]|
    }

    for key <- keys() do
      view |> element("#settings-tab-#{key}") |> render_click()
      assert_showing(view, key)
      assert has_element?(view, where[key])
    end
  end

  test "Save shows on General and Features only", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    save = "#board-form-save"

    for key <- keys() do
      view |> element("#settings-tab-#{key}") |> render_click()
      assert has_element?(view, save <> ~s| button[type="submit"]|)
      hidden? = has_element?(view, save <> ".hidden")
      if key in ~w(general features), do: refute(hidden?), else: assert(hidden?, key)
    end
  end

  test "?tab= opens on that tab", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=gardening")
    assert_showing(view, "gardening")
  end

  test "a tab there is no such thing as opens General", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings?tab=nonsense")
    assert_showing(view, "general")

    view |> element("#settings-tab-sharing") |> render_click()
    view |> element("#settings-tab-sharing") |> render_click(%{"tab" => "nonsense"})
    assert_showing(view, "general")
  end

  test "a board update while open leaves the tab alone", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    view |> element("#settings-tab-planning") |> render_click()

    {:ok, _} = Boards.update_board(board, %{"description" => "changed elsewhere"})
    send(view.pid, {:board_changed, board.id})

    assert_showing(view, "planning")
  end

  test "what is typed on General is saved from Features", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

    view |> form("#board-form", board: %{name: "Renamed"}) |> render_change()
    view |> element("#settings-tab-features") |> render_click()

    view
    |> form("#board-form", board: %{show_pulse: "true"})
    |> render_submit()

    board = Boards.get_board!(board.id)
    assert board.name == "Renamed"
    assert board.show_pulse
  end

  test "the Tidy-up page links to the Gardening tab", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/tidy")
    assert has_element?(view, ~s|a[href="/boards/#{board.id}/settings?tab=gardening"]|)
  end
end
