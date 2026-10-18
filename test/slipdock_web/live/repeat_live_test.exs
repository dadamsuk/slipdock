defmodule SlipdockWeb.RepeatLiveTest do
  @moduledoc """
  Recurring cards in the browser (W-1802): the Repeat… form with its presets,
  preview and refusals; the series' own controls; the ↻ on the card's front;
  and quick add's `every:`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Recurrence}

  setup %{user: owner} do
    {:ok, owner} = Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{}, owner: owner)
    [backlog | _] = board.columns
    # Tuesday 12 January 2027.
    card = card_fixture(backlog, %{"title" => "Review invoices", "due_date" => "2027-01-12"})
    %{owner: owner, board: board, backlog: backlog, card: card}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  test "Repeat… offers presets for the card's date and previews the choice", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)
    assert has_element?(view, "#repeat-edit", "Repeat…")

    view |> element("#repeat-edit") |> render_click()

    assert has_element?(
             view,
             ~s|#repeat-form option[value="FREQ=WEEKLY;BYDAY=TU"]|,
             "Weekly on Tuesday"
           )

    assert has_element?(
             view,
             ~s|#repeat-form option[value="FREQ=MONTHLY;BYDAY=2TU"]|,
             "second Tuesday"
           )

    assert has_element?(view, ~s|#repeat-form option[value="custom"]|)
    # Weekly on the card's day is the starting choice, previewed.
    assert has_element?(view, "#repeat-summary", "Every week on Tue, 07:00 Europe/London")

    assert has_element?(
             view,
             "#repeat-dates",
             "Tue 12 Jan 2027, Tue 19 Jan 2027, Tue 26 Jan 2027"
           )

    html =
      view
      |> form("#repeat-form", repeat: %{preset: "custom"})
      |> render_change()

    assert html =~ ~s(name="repeat[custom]")

    view
    |> form("#repeat-form", repeat: %{preset: "custom", custom: "month last fri", at: "09:00"})
    |> render_change()

    assert has_element?(
             view,
             "#repeat-summary",
             "Every month on the last Friday, 09:00 Europe/London"
           )

    assert has_element?(view, "#repeat-dates", "Fri 29 Jan 2027")
  end

  test "saving sets the series; the panel shows it, and skip, pause and stop work", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)
    view |> element("#repeat-edit") |> render_click()

    view
    |> form("#repeat-form",
      repeat: %{preset: "FREQ=WEEKLY;BYDAY=TU", at: "08:00", lead_days: "1", on_missed: "stack"}
    )
    |> render_submit()

    series = Recurrence.for_card(ctx.card)
    assert series.rule == "FREQ=WEEKLY;BYDAY=TU"
    assert series.create_at == ~T[08:00:00]
    assert series.lead_days == 1
    assert series.on_missed == "stack"
    assert series.timezone == "Europe/London"

    refute has_element?(view, "#repeat-form")
    assert has_element?(view, "#repeat-current", "↻ Every week on Tue, 08:00 Europe/London")
    assert has_element?(view, "#repeat-state", "Next due Tue 19 Jan, made Mon 18 Jan 08:00.")
    assert has_element?(view, "#repeat-edit", "Change…")

    view |> element("#repeat-skip") |> render_click()
    assert Recurrence.for_card(ctx.card).next_on == ~D[2027-01-26]
    assert has_element?(view, "#repeat-state", "Next due Tue 26 Jan")

    view |> element("#repeat-pause") |> render_click()
    assert Recurrence.for_card(ctx.card).paused
    assert has_element?(view, "#repeat-state", "Paused.")
    view |> element("#repeat-pause", "Resume") |> render_click()
    refute Recurrence.for_card(ctx.card).paused

    view |> element("#repeat-stop") |> render_click()
    assert Recurrence.for_card(ctx.card) == nil
    assert has_element?(view, "#repeat-edit", "Repeat…")
  end

  test "Change… opens on the series as it is, a custom rule as custom", ctx do
    {:ok, _} =
      Recurrence.set(
        ctx.card,
        %{"rule" => "2w mon thu", "ends" => "after", "count" => 6},
        ctx.owner
      )

    {:ok, view, _} = open(ctx.conn, ctx)
    view |> element("#repeat-edit") |> render_click()

    assert has_element?(view, ~s|#repeat-form option[value="custom"][selected]|)

    assert has_element?(
             view,
             ~s|#repeat-form input[name="repeat[custom]"][value="FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH"]|
           )

    assert has_element?(view, ~s|#repeat-form input[name="repeat[count]"][value="6"]|)

    view |> element("#repeat-form button", "Cancel") |> render_click()
    refute has_element?(view, "#repeat-form")
  end

  test "a rule it can't read is said, and nothing is saved", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)
    view |> element("#repeat-edit") |> render_click()
    view |> form("#repeat-form", repeat: %{preset: "custom"}) |> render_change()

    view
    |> form("#repeat-form", repeat: %{preset: "custom", custom: "now and then"})
    |> render_change()

    assert has_element?(view, "#repeat-error")
    refute has_element?(view, "#repeat-preview")

    view
    |> form("#repeat-form", repeat: %{preset: "custom", custom: "now and then"})
    |> render_submit()

    assert has_element?(view, "#repeat-error", "rule:")
    assert Recurrence.for_card(ctx.card) == nil

    view |> form("#repeat-form", repeat: %{preset: "FREQ=DAILY", ends: "on"}) |> render_change()

    view
    |> form("#repeat-form", repeat: %{preset: "FREQ=DAILY", ends: "on", ends_on: ""})
    |> render_submit()

    assert has_element?(view, "#repeat-error", "ends_on")
    assert Recurrence.for_card(ctx.card) == nil
  end

  test "a reader sees how it repeats but changing it is refused", ctx do
    {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "tue"}, ctx.owner)
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
    {:ok, view, _} = open(log_in_user(build_conn(), reader), ctx)

    assert has_element?(view, "#repeat-current", "Every week on Tue")
    view |> element("#repeat-stop") |> render_click()
    assert Recurrence.for_card(ctx.card)
  end

  test "an earlier instance says the series moved on", ctx do
    {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "tue"}, ctx.owner)
    {:ok, _} = Boards.update_card(ctx.card, %{"completed" => true})
    Recurrence.tick(~U[2027-01-19 07:00:00Z])

    {:ok, view, _} = open(ctx.conn, ctx)
    assert render(view) =~ "An earlier instance of a recurring card"
  end

  test "the front of a recurring card carries ↻, with the rule as its tooltip", ctx do
    plain = card_fixture(ctx.backlog, %{"title" => "One-off"})
    {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "tue"}, ctx.owner)
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    assert has_element?(
             view,
             ~s|.kanban-card[data-id="#{ctx.card.id}"] [data-role=recurrence-mark][title^="Repeats: Every week on Tue"]|
           )

    refute has_element?(view, ~s|.kanban-card[data-id="#{plain.id}"] [data-role=recurrence-mark]|)
  end

  test "a list's quick add row takes every:, with a chip while typing", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")

    html =
      view
      |> form("#table-add", %{"title" => "Pay rent every: month 1"})
      |> render_change()

    assert html =~ "↻ Every month on the 1st"

    view
    |> form("#table-add", %{"title" => "Pay rent every: month 1"})
    |> render_submit()

    card =
      ctx.board
      |> reload()
      |> Map.get(:columns)
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.title == "Pay rent"))

    assert Recurrence.for_card(card).rule == "FREQ=MONTHLY;BYMONTHDAY=1"
  end
end
