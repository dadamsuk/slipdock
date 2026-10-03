defmodule SlipdockWeb.OutlineLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    tree_fixture()
  end

  test "the outline shows the tree, collapses, limits depth and drills down", ctx do
    conn = build_conn() |> log_in_user(user_fixture())
    {:ok, view, html} = live(conn, ~p"/boards/#{ctx.board}/outline")

    for title <- ~w(Epic B C D E Late Stuck Loose), do: assert(html =~ title)
    assert has_element?(view, "#ol-#{ctx.epic.id}[data-level='0']")
    assert has_element?(view, "#ol-#{ctx.c.id}[data-level='1']")
    assert has_element?(view, "#ol-#{ctx.e.id}[data-level='2']")
    # Rolled-up progress and health on the epic row.
    assert has_element?(view, "#ol-#{ctx.epic.id} progress[value='2'][max='3']")
    assert has_element?(view, "#ol-#{ctx.epic.id} span[title='At risk']")
    assert has_element?(view, "#ol-#{ctx.stuck.id} span[title='Blocked']")
    assert has_element?(view, "#ol-#{ctx.c.id} span[title^='Subcards run until']", "+12d")
    # Cards on other boards link into their board's outline.
    assert has_element?(
             view,
             "#ol-#{ctx.e.id} a[href='/boards/#{ctx.subsub.id}/outline/cards/#{ctx.e.id}']"
           )

    # Collapsing hides the subtree.
    view
    |> element("#ol-#{ctx.epic.id} button[phx-value-key='card-#{ctx.epic.id}']")
    |> render_click()

    refute has_element?(view, "#ol-#{ctx.c.id}")
    assert has_element?(view, "#ol-#{ctx.epic.id}")

    # Depth from the URL.
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/outline?depth=1")
    assert has_element?(view, "#ol-#{ctx.epic.id}")
    refute has_element?(view, "#ol-#{ctx.b.id}")
    assert has_element?(view, "#ol-#{ctx.epic.id} a[href='/boards/#{ctx.sub.id}/outline']")
    assert has_element?(view, "select[name=depth] option[value='1'][selected]")

    # The toolbar's depth select patches the URL.
    view |> form("#swim-config", %{"depth" => "2"}) |> render_change()
    assert_patch(view, ~p"/boards/#{ctx.board}/outline?depth=2")
    assert has_element?(view, "#ol-#{ctx.b.id}")
    refute has_element?(view, "#ol-#{ctx.d.id}")

    # Completing a card on a sub-board from the outline rolls up live.
    view |> element("#ol-#{ctx.c.id} button[title='Mark complete']") |> render_click()
    assert Boards.get_card!(ctx.c.id).completed

    # A sub-board's outline starts at that level.
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.sub}/outline")
    assert has_element?(view, "#ol-#{ctx.b.id}[data-level='0']")
    assert has_element?(view, "#ol-#{ctx.e.id}[data-level='1']")
    refute has_element?(view, "#ol-#{ctx.epic.id}")
  end

  test "the timeline opens subcards beneath a bar and moves them", ctx do
    conn = build_conn() |> log_in_user(user_fixture())
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/timeline?date=2030-01-15")
    assert has_element?(view, "#tl-all-#{ctx.epic.id}[data-level='0']")
    refute has_element?(view, "#tl-all-#{ctx.c.id}")
    assert has_element?(view, "select[name=depth]")

    view |> form("#swim-config", %{"depth" => "all"}) |> render_change()
    assert has_element?(view, "#tl-all-#{ctx.c.id}[data-level='1']")
    assert has_element?(view, "#tl-all-#{ctx.e.id}[data-level='2']")
    # A derived bar is locked; an own-dated child bar is not.
    assert has_element?(view, "#tl-bar-all-#{ctx.epic.id}[data-locked='true']")
    assert has_element?(view, "#tl-bar-all-#{ctx.c.id}[data-locked='false']")

    # Collapse the epic's subcards.
    view
    |> element("#tl-all-#{ctx.epic.id} button[phx-value-key='card-#{ctx.epic.id}']")
    |> render_click()

    refute has_element?(view, "#tl-all-#{ctx.c.id}")

    # Dragging a subcard's bar (on another board of the tree) moves it.
    render_hook(view, "timeline_move", %{"id" => ctx.c.id, "edge" => "both", "delta" => 2})
    c = Boards.get_card!(ctx.c.id)
    assert c.start_date == ~D[2030-01-07] and c.due_date == ~D[2030-01-22]
  end
end
