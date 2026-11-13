defmodule SlipdockWeb.WikiLive.TreeToggleAllTest do
  @moduledoc """
  The wiki tree's open-or-close-all button (#2761). The server draws it as
  it first is, every folder shut, so its arrows point down to open them;
  the tree's hook turns them up once a folder is open, and the server
  leaves it alone after that.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Wiki

  test "is drawn with its arrows down, to open every folder", %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Toggle", "code" => "toggle2761"}, owner: user)
    {:ok, _} = Wiki.create_folder(board, %{"name" => "Runbooks"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    assert has_element?(view, "#wiki-tree-toggle-all .hero-chevron-double-down")
    refute has_element?(view, "#wiki-tree-toggle-all .hero-chevron-double-up")
  end
end
