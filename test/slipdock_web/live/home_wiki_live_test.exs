defmodule SlipdockWeb.HomeWikiLiveTest do
  @moduledoc """
  The home page and the one wiki (W-2201): the Wiki link opens it, there is no
  vault tile among the boards, and the Knowledge Base, being a wiki and not a
  board to work on, is listed nowhere a board is.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Wiki.KnowledgeBase

  setup %{user: user} do
    alpha = board_fixture(%{"name" => "Alpha", "code" => "hwalpha"}, owner: user)
    {:ok, kb} = KnowledgeBase.ensure(user)
    %{alpha: alpha, kb: kb}
  end

  defp tiles(html) do
    ~r/\sid="(board|vault|multiboard)-(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, kind, id] -> {String.to_atom(kind), String.to_integer(id)} end)
  end

  test "the Wiki link opens the wiki; there is no vault tile", %{conn: conn, alpha: alpha} do
    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "a[href='/wiki']", "Wiki")
    refute has_element?(view, "[id^=vault-tile-]")
    assert tiles(html) == [board: alpha.id]
  end

  # #1662: the link sits on the left, before the board count, and only there.
  test "the Wiki link sits on the left, before the board count", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "h1 + p > a#open-wiki[href='/wiki']", "Wiki")
    assert has_element?(view, "h1 + p > #board-count", "1 board")

    [_, after_link] = String.split(html, ~s(id="open-wiki"), parts: 2)
    assert after_link =~ ~s(id="board-count")

    # No longer among the buttons on the right, beside Multiboard.
    assert has_element?(view, "#open-multiboard")
    refute has_element?(view, "#open-multiboard ~ a[href='/wiki']")
    refute has_element?(view, "#multiboard-count")
  end

  test "the Knowledge Base is no tile, in either layout or among the archived", ctx do
    %{conn: conn, user: user, kb: kb} = ctx

    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#board-#{kb.id}")

    {:ok, _} = Slipdock.Accounts.update_board_view(user, %{"board_layout" => "compact"})
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#board-#{kb.id}")
    refute render(view) =~ KnowledgeBase.name()
  end

  test "it is no choice in the switcher or the board list API", %{conn: conn, kb: kb} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#switch-board-#{kb.id}")

    boards = conn |> get(~p"/api/boards") |> json_response(200) |> Map.fetch!("boards")
    refute Enum.any?(boards, &(&1["id"] == kb.id))
  end

  test "its board view opens as its place in the wiki", %{conn: conn, kb: kb} do
    assert {:error, {:live_redirect, %{to: "/wiki/Knowledge%20Base"}}} =
             live(conn, ~p"/boards/#{kb.id}")
  end

  test "it counts against no board limit", %{user: user} do
    before = Slipdock.Quota.used(user.id, :boards)
    {:ok, other} = Boards.create_board(%{"name" => "Another"}, owner_id: user.id)
    assert Slipdock.Quota.used(user.id, :boards) == before + 1
    assert Boards.Board.wiki?(KnowledgeBase.get(user))
    refute Boards.Board.wiki?(other)
  end
end
