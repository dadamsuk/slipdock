defmodule SlipdockWeb.RoadmapLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Plan"})
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Thing", "due_date" => "2030-01-20"})
    %{board: reload(board), card: card, backlog: backlog}
  end

  test "posting a status update shows the reported health", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")

    view
    |> form("#status-form-0", %{"health" => "at_risk", "body" => "Waiting on legal"})
    |> render_submit()

    html = render(view)
    assert html =~ "Waiting on legal"
    assert html =~ "At risk"
    assert Slipdock.Boards.Card.stated_health(Boards.get_card!(card.id)) == "at_risk"
  end

  test "the list settings modal saves a category and horizon", %{
    conn: conn,
    board: board,
    backlog: backlog
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    render_click(view, "edit_column", %{"id" => to_string(backlog.id)})

    view
    |> form("#column-form", %{
      "column" => %{
        "name" => "Q1",
        "category" => "doing",
        "horizon_from" => "2030-01-01",
        "horizon_to" => "2030-03-31",
        "horizon_unit" => "quarter"
      }
    })
    |> render_submit()

    column = Boards.get_column!(backlog.id)
    assert column.category == "doing"
    assert column.horizon_to == ~D[2030-03-31]
    assert render(view) =~ "Q1 2030"
  end

  test "milestones are added from board settings and drawn on the timeline", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

    view
    |> form("#milestone-form-0", %{"name" => "Launch", "date" => "2030-01-25", "color" => "rose"})
    |> render_submit()

    assert [%{name: "Launch"}] = Boards.list_milestones(board.id)

    {:ok, tl, html} = live(conn, ~p"/boards/#{board}/timeline?date=2030-01-15&unit=month")
    assert html =~ "Launch"
    assert has_element?(tl, ".tl-ms-diamond")
  end

  test "a published view is readable without signing in, and stops when unpublished", %{
    board: board
  } do
    {:ok, view} =
      Boards.create_saved_view(board, %{
        "name" => "Public plan",
        "config" => %{"mode" => "table", "fields" => ["title", "due_date"]}
      })

    {:ok, view} = Boards.publish_saved_view(view)
    anon = Phoenix.ConnTest.build_conn()

    {:ok, lv, html} = live(anon, ~p"/p/#{view.public_token}")
    assert html =~ "Published view"
    assert html =~ "Thing"
    refute has_element?(lv, "#swim-config")

    {:ok, _} = Boards.unpublish_saved_view(view)
    assert {:error, {:redirect, %{to: "/login"}}} = live(anon, ~p"/p/#{view.public_token}")
    assert {:error, {:redirect, %{to: "/login"}}} = live(anon, ~p"/p/nonsense")
  end

  test "the table exports as CSV with the page's parameters", %{conn: conn, board: board} do
    conn = get(conn, ~p"/boards/#{board}/export.csv?fields=title,due_date")
    assert response_content_type(conn, :csv) =~ "text/csv"
    assert conn.resp_body =~ "Title,Due\r\nThing,2030-01-20"

    stranger = conn_as(user_fixture("other@example.com"))
    assert get(stranger, ~p"/boards/#{board}/export.csv").status == 403
  end

  test "the timeline carries dependency links and the display menu offers colour by", %{
    conn: conn,
    board: board,
    card: card,
    backlog: backlog
  } do
    other = card_fixture(backlog, %{"title" => "First", "due_date" => "2030-01-25"})
    {:ok, _} = Boards.add_dependency(card, other)

    {:ok, lv, html} =
      live(conn, ~p"/boards/#{board}/timeline?date=2030-01-15&unit=month&color_by=priority")

    assert html =~ ~s(data-links=)
    assert html =~ "violated&quot;:true"
    assert has_element?(lv, "#color-legend")
    assert has_element?(lv, "select[name=color_by]")
  end
end
