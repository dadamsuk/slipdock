defmodule SlipdockWeb.HomeMultiboardsLiveTest do
  @moduledoc """
  Saved multiboards on the home page (#1482): a tile among the boards and
  vaults, in its own colour, moved like a board, recoloured and deleted from
  its menu.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Slipdock.{Multiboard, Repo}

  setup %{user: user} do
    alpha = board_fixture(%{"name" => "Alpha", "code" => "almbh"}, owner: user)
    zulu = board_fixture(%{"name" => "Zulu", "code" => "zumbh"}, owner: user)
    [_, todo | _] = alpha.columns
    [_, zulu_todo, zulu_doing | _] = zulu.columns

    {:ok, mb} =
      Multiboard.create_saved(user, %{"name" => "Queue", "color" => "rose"}, %{
        lists: [todo.id, zulu_todo.id, zulu_doing.id],
        top: 3,
        by: "list"
      })

    # A second apart, as made by hand: alpha, the multiboard, then zulu.
    for {schema, id, ago} <- [
          {Slipdock.Boards.Board, alpha.id, 20},
          {Multiboard.Saved, mb.id, 10}
        ] do
      at = DateTime.add(DateTime.utc_now(:second), -ago)
      Repo.update_all(from(x in schema, where: x.id == ^id), set: [inserted_at: at])
    end

    %{alpha: alpha, zulu: zulu, mb: mb}
  end

  defp tiles(html) do
    ~r/\sid="(board|multiboard)-(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, kind, id] -> {String.to_atom(kind), String.to_integer(id)} end)
  end

  test "a tile among the boards: its name, colour, boards and lists, linking to it", ctx do
    %{conn: conn, alpha: alpha, zulu: zulu, mb: mb} = ctx
    {:ok, view, html} = live(conn, ~p"/")

    assert tiles(view |> element("#boards") |> render()) ==
             [board: alpha.id, multiboard: mb.id, board: zulu.id]

    assert html =~ "1 multiboard"
    tile = "#multiboard-#{mb.id}"
    assert has_element?(view, "#{tile}[data-id='multiboard-#{mb.id}']")
    assert has_element?(view, "#{tile} a[href='/multiboard/#{mb.id}']", "Queue")
    assert has_element?(view, tile, "Alpha · Zulu")
    assert has_element?(view, tile, "3 lists")
    assert has_element?(view, tile, "top 3")
    assert has_element?(view, "#{tile} .bg-gradient-to-br[class*='rose']")
    assert has_element?(view, "#{tile} .board-handle")
  end

  test "is in the compact list too", %{conn: conn, mb: mb} do
    {:ok, view, _} = live(conn, ~p"/")
    html = view |> element("button[phx-value-layout=compact]") |> render_click()

    assert html =~ "<table"
    assert has_element?(view, "tr#multiboard-#{mb.id} a[href='/multiboard/#{mb.id}']", "Queue")
    assert has_element?(view, "tr#multiboard-#{mb.id}", "Alpha · Zulu")
  end

  test "a list on a board you can no longer read doesn't count", %{conn: conn, user: user} do
    stranger = user_fixture("mbh-stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "thmbh"}, owner: stranger)
    [_, their_todo | _] = theirs.columns

    {:ok, mb} =
      Multiboard.create_saved(user, %{"name" => "Leaky"}, %{lists: [their_todo.id]})

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#multiboard-#{mb.id}", "0 lists")
    assert has_element?(view, "#multiboard-#{mb.id}", "No lists chosen yet")
    refute has_element?(view, "#multiboard-#{mb.id}", "Theirs")
  end

  test "is moved like a board, and the order is kept", ctx do
    %{conn: conn, alpha: alpha, zulu: zulu, mb: mb} = ctx
    {:ok, view, _} = live(conn, ~p"/")

    html = render_click(view, "nudge", %{"id" => "multiboard-#{mb.id}", "dir" => "up"})
    assert tiles(html) == [multiboard: mb.id, board: alpha.id, board: zulu.id]
    refute has_element?(view, "#multiboard-#{mb.id} button[phx-value-dir=up]")
    assert has_element?(view, "#multiboard-#{mb.id} button[phx-value-dir=down]")

    html = render_hook(view, "reorder", %{"id" => "multiboard-#{mb.id}", "before" => nil})
    assert tiles(html) == [board: alpha.id, board: zulu.id, multiboard: mb.id]

    html =
      render_hook(view, "reorder", %{
        "id" => to_string(zulu.id),
        "before" => "multiboard-#{mb.id}"
      })

    assert tiles(html) == [board: alpha.id, board: zulu.id, multiboard: mb.id]

    {:ok, _view, html} = live(conn, ~p"/")
    assert tiles(html) == [board: alpha.id, board: zulu.id, multiboard: mb.id]
  end

  test "follows the sort by name", %{conn: conn, alpha: alpha, zulu: zulu, mb: mb} do
    {:ok, view, _} = live(conn, ~p"/")
    html = view |> form("#board-sort", %{"sort" => "name"}) |> render_change()
    assert tiles(html) == [board: alpha.id, multiboard: mb.id, board: zulu.id]
    refute has_element?(view, "#multiboard-#{mb.id} .board-handle")
  end

  test "its menu recolours it", %{conn: conn, mb: mb} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#multiboard-color-#{mb.id}-rose[aria-pressed=true]")

    view |> element("#multiboard-color-#{mb.id}-teal") |> render_click()

    assert Repo.reload(mb).color == "teal"
    assert has_element?(view, "#multiboard-#{mb.id} .bg-gradient-to-br[class*='teal']")
    assert has_element?(view, "#multiboard-color-#{mb.id}-teal[aria-pressed=true]")
  end

  test "an unknown colour changes nothing", %{conn: conn, mb: mb} do
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "multiboard_color", %{"id" => to_string(mb.id), "color" => "plaid"})
    assert Repo.reload(mb).color == "rose"
  end

  test "its menu deletes it, leaving the boards", %{conn: conn, user: user, mb: mb, alpha: alpha} do
    {:ok, view, _} = live(conn, ~p"/")
    html = view |> element("#multiboard-delete-#{mb.id}") |> render_click()

    assert html =~ "Multiboard “Queue” deleted."
    refute has_element?(view, "#multiboard-#{mb.id}")
    assert Multiboard.list_saved(user) == []
    assert has_element?(view, "#board-#{alpha.id}")
  end

  test "somebody else's can't be recoloured, deleted or moved by naming it", ctx do
    %{conn: conn, alpha: alpha, zulu: zulu, mb: mb} = ctx
    stranger = user_fixture("mbh-stranger2@example.com")
    {:ok, theirs} = Multiboard.create_saved(stranger, %{"name" => "Theirs"}, %{})
    {:ok, view, html} = live(conn, ~p"/")

    refute html =~ "Theirs"
    render_click(view, "multiboard_color", %{"id" => to_string(theirs.id), "color" => "teal"})
    render_click(view, "delete_multiboard", %{"id" => to_string(theirs.id)})
    html = render_hook(view, "reorder", %{"id" => "multiboard-#{theirs.id}", "before" => nil})

    assert %{color: "indigo", position: nil} = Repo.reload(theirs)
    assert tiles(html) == [board: alpha.id, multiboard: mb.id, board: zulu.id]
  end

  test "a multiboard saved elsewhere appears without a reload", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/")
    {:ok, fresh} = Multiboard.create_saved(user, %{"name" => "Fresh"}, %{})
    send(view.pid, {:boards_changed})
    assert has_element?(view, "#multiboard-#{fresh.id}", "Fresh")
  end
end
