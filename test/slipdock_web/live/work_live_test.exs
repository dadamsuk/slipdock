defmodule SlipdockWeb.WorkLiveTest do
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  test "my work lists assigned cards across boards with their paths, grouped by due" do
    user = user_fixture()
    ctx = tree_fixture()
    other = board_fixture(%{"name" => "Other"})
    [col | _] = other.columns
    today = Date.utc_today()

    {:ok, _} =
      Boards.update_card(ctx.e, %{"assignee_id" => user.id, "due_date" => Date.add(today, -3)})

    {:ok, _} = Boards.update_card(ctx.b, %{"assignee_id" => user.id})

    soon =
      card_fixture(col, %{
        "title" => "Soon",
        "assignee_id" => user.id,
        "due_date" => Date.add(today, 2)
      })

    _unassigned = card_fixture(col, %{"title" => "Nobody's"})

    conn = build_conn() |> log_in_user(user)
    {:ok, view, html} = live(conn, ~p"/work")

    assert html =~ "2 open cards assigned to you"
    assert has_element?(view, "#work-overdue #work-card-#{ctx.e.id}")
    assert has_element?(view, "#work-week #work-card-#{soon.id}")
    refute html =~ "Nobody&#39;s"
    # B is completed: hidden until asked for.
    refute has_element?(view, "#work-card-#{ctx.b.id}")
    # The path shows where E sits in its tree.
    assert has_element?(view, "#work-card-#{ctx.e.id} p[title='Root › Epic › C']")

    assert has_element?(
             view,
             "#work-card-#{ctx.e.id} a[href='/boards/#{ctx.subsub.id}/cards/#{ctx.e.id}']"
           )

    view |> element("label input[phx-click=toggle_done]") |> render_click()
    assert has_element?(view, "#work-done #work-card-#{ctx.b.id}")

    view |> element("#work-card-#{soon.id} button[title='Mark complete']") |> render_click()
    assert Boards.get_card!(soon.id).completed
    assert has_element?(view, "#work-done #work-card-#{soon.id}")
  end
end
