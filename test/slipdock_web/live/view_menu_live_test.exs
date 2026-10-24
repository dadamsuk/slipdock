defmodule SlipdockWeb.ViewMenuLiveTest do
  @moduledoc """
  The view switcher at the head of every board toolbar (#1274): the views
  and the Wiki, and no longer a "Write this into a doc" entry.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Settings

  setup %{user: user} do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    %{board: board_fixture(%{"name" => "View menu"}, owner: user)}
  end

  for suffix <- ["", "/outline", "/table", "/swimlanes"] do
    test "#{if suffix == "", do: "/board", else: suffix} has the Wiki but no Write into a doc",
         %{conn: conn, board: board} do
      {:ok, view, html} = live(conn, "/boards/#{board.id}#{unquote(suffix)}")

      assert has_element?(view, ~s|ul[aria-label="View mode"] a[href="/boards/#{board.id}/wiki"]|)
      refute html =~ "Write this into a doc"
      refute has_element?(view, ~s|ul[aria-label="View mode"] a[href*="/wiki/new"]|)
    end
  end
end
