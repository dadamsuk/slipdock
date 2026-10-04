defmodule SlipdockWeb.TimeTrackingTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Hours"})
    card = card_fixture(hd(board.columns), %{"title" => "Timed"})
    %{board: board, card: card}
  end

  test "spent and estimate are minutes, read in the card's unit", %{card: card} do
    assert card.time_unit == "hours"

    {:ok, card} = Boards.update_card(card, %{"time_spent" => "1.5", "time_estimate" => "4"})
    assert {card.time_spent, card.time_estimate} == {90, 240}

    # Changing the unit doesn't change the time recorded.
    {:ok, card} = Boards.update_card(card, %{"time_unit" => "days"})
    assert {card.time_spent, card.time_estimate} == {90, 240}

    assert {:error, cs} = Boards.update_card(card, %{"time_unit" => "fortnights"})
    assert cs.errors[:time_unit]
    assert {:error, cs} = Boards.update_card(card, %{"time_spent" => "a while"})
    assert cs.errors[:time_spent]

    {:ok, card} = Boards.update_card(card, %{"time_estimate" => ""})
    assert card.time_estimate == nil
  end

  test "the timer adds what it ran to time spent, and both are logged",
       %{board: board, card: card} do
    {:ok, card} = Boards.update_card(card, %{"time_spent" => "1h"})
    {:ok, card} = Boards.start_timer(card)
    assert card.timer_started_at

    # Starting again keeps the original start.
    started = card.timer_started_at
    {:ok, again} = Boards.start_timer(card)
    assert again.timer_started_at == started

    # Pretend it has been running for 45 minutes.
    {:ok, card} =
      card
      |> Ecto.Changeset.change(timer_started_at: DateTime.add(started, -45 * 60, :second))
      |> Slipdock.Repo.update()

    {:ok, card} = Boards.stop_timer(card)
    assert card.timer_started_at == nil
    assert card.time_spent == 105

    assert {:ok, ^card} = Boards.stop_timer(card)

    messages = Enum.map(Boards.list_activities(board.id), & &1.message)
    assert Enum.any?(messages, &(&1 =~ "started the timer"))
    assert Enum.any?(messages, &(&1 =~ "logged 0.75h"))
  end

  test "the API reads and writes it, logs time and runs the timer", %{conn: conn, card: card} do
    conn = put_req_header(conn, "accept", "application/json")

    body =
      conn
      |> patch(~p"/api/cards/#{card.id}", %{
        "time_unit" => "days",
        "time_estimate" => "2",
        "time_spent" => "4h"
      })
      |> json_response(200)

    assert %{
             "unit" => "days",
             "spent" => 0.5,
             "estimate" => 2,
             "spent_minutes" => 240,
             "estimate_minutes" => 960,
             "percent" => 25,
             "timer_running" => false
           } = body["card"]["time"]

    body =
      conn |> patch(~p"/api/cards/#{card.id}", %{"log_time" => "2.5d"}) |> json_response(200)

    assert body["card"]["time"]["spent"] == 3
    assert body["card"]["time"]["percent"] == 150

    assert conn
           |> patch(~p"/api/cards/#{card.id}", %{"log_time" => "ages"})
           |> json_response(422)

    body =
      conn |> post(~p"/api/cards/#{card.id}/timer", %{"action" => "start"}) |> json_response(200)

    assert body["card"]["time"]["timer_running"]
    assert body["card"]["time"]["timer_started_at"]

    body =
      conn |> post(~p"/api/cards/#{card.id}/timer", %{"action" => "stop"}) |> json_response(200)

    refute body["card"]["time"]["timer_running"]

    assert conn
           |> post(~p"/api/cards/#{card.id}/timer", %{"action" => "pause"})
           |> json_response(422)
  end

  test "the card panel sets them, shows the bar and runs the timer",
       %{conn: conn, board: board, card: card} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    view
    |> form("#card-time-form", card: %{time_estimate: "2"})
    |> render_change(%{"_target" => ["card", "time_estimate"]})

    view
    |> form("#card-time-form", card: %{time_spent: "3"})
    |> render_change(%{"_target" => ["card", "time_spent"]})

    card = Boards.get_card!(card.id)
    assert {card.time_spent, card.time_estimate} == {180, 120}

    html = render(view)
    assert html =~ "150%"
    assert html =~ "1h over"
    assert has_element?(view, ~s|#card-time-progress [data-status="over"]|)

    # Switching the unit re-reads nothing: the values on screen were hours.
    view
    |> form("#card-time-form", card: %{time_unit: "minutes"})
    |> render_change(%{"_target" => ["card", "time_unit"]})

    card = Boards.get_card!(card.id)
    assert {card.time_unit, card.time_spent, card.time_estimate} == {"minutes", 180, 120}

    view |> form("#card-log-time-0", %{amount: "20m"}) |> render_submit()
    assert Boards.get_card!(card.id).time_spent == 200

    view |> element("#card-timer-toggle") |> render_click()
    assert Boards.get_card!(card.id).timer_started_at
    assert has_element?(view, "#card-timer-toggle [phx-hook=Elapsed]")

    view |> element("#card-timer-toggle") |> render_click()
    assert Boards.get_card!(card.id).timer_started_at == nil
  end

  test "export and import carry it", %{board: board, card: card} do
    {:ok, _} =
      Boards.update_card(card, %{
        "time_unit" => "days",
        "time_spent" => "1",
        "time_estimate" => "3"
      })

    user = Slipdock.Repo.get!(Slipdock.Accounts.User, board.owner_id)
    doc = user |> Slipdock.Portable.export() |> Jason.encode!()
    {:ok, _} = Slipdock.Portable.import(user, doc)

    copies =
      Slipdock.Repo.all(
        from c in Slipdock.Boards.Card, where: c.title == "Timed" and c.id != ^card.id
      )

    assert [%{time_unit: "days", time_spent: 480, time_estimate: 1440}] = copies
  end
end
