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
    assert Boards.Cards.get_card!(ctx.c.id).completed

    # A sub-board's outline starts at that level.
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.sub}/outline")
    assert has_element?(view, "#ol-#{ctx.b.id}[data-level='0']")
    assert has_element?(view, "#ol-#{ctx.e.id}[data-level='1']")
    refute has_element?(view, "#ol-#{ctx.epic.id}")
  end

  test "the outline pages at 250 rows, keeps epics whole, splits only a big one" do
    board = board_fixture(%{"name" => "Big"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    # Two top-level cards and 402 rows: 100 subcards under one, 300 under the other.
    small = card_fixture(hd(board.columns), %{"title" => "Small epic"})
    big = card_fixture(hd(board.columns), %{"title" => "Big epic"})
    small_kids = subcards(small, t, 100)
    big_kids = subcards(big, t, 300)

    conn = build_conn() |> log_in_user(user_fixture())
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/outline")

    # Page 1: the small epic whole; the big one doesn't fit what is left.
    assert has_element?(view, "#outline-page-of", "Page 1 of 3")
    assert has_element?(view, "#outline-page-range", "1–101 of 402 rows")
    assert has_element?(view, "#outline-prev[disabled]")
    assert has_element?(view, "#ol-#{List.last(small_kids).id}")
    refute has_element?(view, "#ol-#{big.id}")
    # Rows are py-1 now, not py-1.5.
    refute html =~ "py-1.5 pr-2"

    # Page 2: the big epic and its first 249 subcards, 250 rows.
    view |> element("#outline-next") |> render_click()
    assert has_element?(view, "#outline-page-of", "Page 2 of 3")
    assert has_element?(view, "#outline-page-range", "102–351 of 402 rows")
    assert has_element?(view, ".ol-row:not(.ol-head)", "Big epic")
    refute has_element?(view, "#ol-#{big.id}", "continued")
    assert has_element?(view, "#ol-#{Enum.at(big_kids, 248).id}")
    refute has_element?(view, "#ol-#{Enum.at(big_kids, 249).id}")
    refute has_element?(view, "#ol-#{small.id}")

    # Page 3: the big epic again, marked as carried on, then the rest.
    view |> element("#outline-next") |> render_click()
    assert has_element?(view, "#outline-page-of", "Page 3 of 3")
    assert has_element?(view, "#outline-page-range", "352–402 of 402 rows")
    assert has_element?(view, "#ol-#{big.id}", "continued")
    assert has_element?(view, "#ol-#{Enum.at(big_kids, 249).id}")
    assert has_element?(view, "#outline-next[disabled]")

    # Collapsing the big epic leaves two rows: one page, no pager.
    view
    |> element("#ol-#{big.id} button[phx-value-key='card-#{big.id}']")
    |> render_click()

    refute has_element?(view, "#outline-pager")
    assert has_element?(view, "#ol-#{small.id}")
  end

  test "pages past the end clamp to the last, before the start to the first" do
    board = board_fixture(%{"name" => "Many"})
    col = hd(board.columns)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Slipdock.Repo.insert_all(
      Slipdock.Boards.Card,
      for(
        n <- 1..251,
        do: %{
          title: "Card #{n}",
          column_id: col.id,
          board_id: board.id,
          position: n,
          inserted_at: now,
          updated_at: now
        }
      )
    )

    conn = build_conn() |> log_in_user(user_fixture())
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/outline")
    assert has_element?(view, "#outline-page-range", "1–250 of 251 rows")
    render_click(view, "outline_page", %{"page" => "9"})
    assert has_element?(view, "#outline-page-of", "Page 2 of 2")
    assert has_element?(view, "#outline-page-range", "251–251 of 251 rows")
    render_click(view, "outline_page", %{"page" => "nonsense"})
    assert has_element?(view, "#outline-page-of", "Page 1 of 2")
  end

  # `n` subcards under `card`, in order, on a new sub-board.
  defp subcards(card, template, n) do
    {:ok, sub} = Boards.create_sub_board(card, template, code: unique_code())
    col = hd(Boards.get_board!(sub.id).columns)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Slipdock.Repo.insert_all(
      Slipdock.Boards.Card,
      for(
        i <- 1..n,
        do: %{
          title: "#{card.title} #{String.pad_leading(to_string(i), 3, "0")}",
          column_id: col.id,
          board_id: sub.id,
          position: i,
          inserted_at: now,
          updated_at: now
        }
      )
    )

    Boards.get_board!(sub.id).columns |> hd() |> Map.get(:cards) |> Enum.sort_by(& &1.position)
  end

  test "one page of cards has no pager", ctx do
    conn = build_conn() |> log_in_user(user_fixture())
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/outline")
    refute has_element?(view, "#outline-pager")
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
    c = Boards.Cards.get_card!(ctx.c.id)
    assert c.start_date == ~D[2030-01-07] and c.due_date == ~D[2030-01-22]
  end
end
