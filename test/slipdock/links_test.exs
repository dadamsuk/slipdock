defmodule Slipdock.LinksTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Swimlanes, Table}
  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes.Config

  test "cards link across boards; goals collect contributions; the goal axis groups by them" do
    roadmap = board_fixture(%{"name" => "Roadmap"})
    delivery = board_fixture(%{"name" => "Delivery"})
    [rcol | _] = roadmap.columns
    [dcol | _] = delivery.columns
    goal = card_fixture(rcol, %{"title" => "Grow retention"})
    a = card_fixture(dcol, %{"title" => "Onboarding emails"})
    b = card_fixture(dcol, %{"title" => "Churn survey", "completed" => true})
    c = card_fixture(dcol, %{"title" => "Unrelated"})

    assert {:ok, _} = Boards.add_link(a, goal, "contributes")
    assert {:ok, _} = Boards.add_link(b, goal, "contributes")
    assert {:ok, _} = Boards.add_link(a, c, "relates")
    assert {:error, msg} = Boards.add_link(c, a, "relates")
    assert msg =~ "already related"
    assert {:error, _} = Boards.add_link(a, goal, "contributes")
    assert {:error, _} = Boards.add_link(a, a, "relates")
    assert {:error, _} = Boards.add_link(a, goal, "bogus")

    goal = Boards.get_card!(goal.id)

    assert [%{title: "Onboarding emails"}, %{title: "Churn survey", completed: true}] =
             Card.contributions(goal)

    a = Boards.get_card!(a.id)
    assert [%{title: "Grow retention", board: %{name: "Roadmap"}}] = Card.goals(a)

    delivery = reload(delivery)
    grid = Swimlanes.grid(delivery, %{Config.defaults("swimlanes") | rows: "goal", cols: "none"})
    assert [%{label: "Grow retention", count: 2}, %{label: "No goal", count: 1}] = grid.rows

    csv = Table.csv(delivery, %{Config.defaults("table") | fields: ~w(title goal links)})
    assert csv =~ "Onboarding emails,Grow retention,contributes Grow retention; relates Unrelated"

    assert [%{id: _}] = Boards.search_cards_across([roadmap.id, delivery.id], "retention")
    assert Boards.search_cards_across([roadmap.id], "retention", [goal.id]) == []

    [link | _] = a.links_out
    assert {:ok, _} = Boards.remove_link(link)
    assert length(Boards.get_card!(a.id).links_out) == 1
  end
end
