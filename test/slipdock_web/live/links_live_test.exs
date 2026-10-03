defmodule SlipdockWeb.LinksLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  test "the card modal searches other boards and links cards", %{conn: conn} do
    roadmap = board_fixture(%{"name" => "Roadmap"})
    delivery = board_fixture(%{"name" => "Delivery"})
    goal = card_fixture(hd(roadmap.columns), %{"title" => "Grow retention"})
    work = card_fixture(hd(delivery.columns), %{"title" => "Onboarding emails"})

    {:ok, view, _} = live(conn, ~p"/boards/#{delivery}/cards/#{work}")

    html =
      view
      |> form("#link-form-0", %{"kind" => "contributes", "q" => "retention"})
      |> render_change()

    assert html =~ "Grow retention"
    html = render_click(view, "add_link", %{"id" => to_string(goal.id)})
    assert html =~ "Contributes to"
    assert html =~ "Roadmap"
    assert [%{kind: "contributes"}] = Boards.get_card!(work.id).links_out

    {:ok, _gv, html} = live(conn, ~p"/boards/#{roadmap}/cards/#{goal}")
    assert html =~ "Contributions"
    assert html =~ "0/1"

    conn = post(conn, ~p"/api/cards/#{work}/links", %{"to" => goal.id, "kind" => "relates"})
    assert length(json_response(conn, 201)["card"]["links"]) == 2
  end
end
