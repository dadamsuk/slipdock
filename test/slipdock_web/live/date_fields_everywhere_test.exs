defmodule SlipdockWeb.DateFieldsEverywhereTest do
  @moduledoc """
  Every place a person sets a date draws a `<.date_field>` and still saves
  through it (#1721): the card back's start and due, the table, the
  timeline tray, Users' paid-up date and the narrative's range.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Settings}

  # A date field: the wrapper, with the hidden native input inside it.
  defp date_field?(view, id), do: has_element?(view, "##{id}[data-date-field] input[type=date]")

  setup %{conn: conn} do
    user = user_fixture("dfe.owner@example.com")
    board = board_fixture(%{"name" => "Dates"}, owner: user)
    [todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Plan", "due_date" => "2030-01-15"})
    %{conn: log_in_user(conn, user), board: board, card: card, todo: todo}
  end

  test "the card back's start and due set, change and clear", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    assert date_field?(view, "card-start-date-#{ctx.card.id}")
    assert date_field?(view, "card-due-date-#{ctx.card.id}")

    assert has_element?(
             view,
             "#card-due-date-#{ctx.card.id} [data-role=date-text]",
             "15 Jan 2030"
           )

    view
    |> form("#card-meta-form", card: %{start_date: "2030-01-10", due_date: "2030-01-20"})
    |> render_change()

    card = Boards.get_card!(ctx.card.id)
    assert {card.start_date, card.due_date} == {~D[2030-01-10], ~D[2030-01-20]}
    assert has_element?(view, "#card-start-date-#{card.id} [data-role=date-text]", "10 Jan 2030")

    view |> form("#card-meta-form", card: %{start_date: ""}) |> render_change()
    assert Boards.get_card!(card.id).start_date == nil
    assert has_element?(view, "#card-start-date-#{card.id} [data-role=date-text]", "Add date")

    # A start after the due date is refused, and says so.
    view |> form("#card-meta-form", card: %{start_date: "2030-02-01"}) |> render_change()
    assert Boards.get_card!(card.id).start_date == nil
    assert render(view) =~ "Start must be on or before the due date."
  end

  test "the table's due is one date field per row, with no chip beside it", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/table")

    view
    |> form("#swim-config", %{"rows" => "none", "fields" => ["title", "start_date", "due_date"]})
    |> render_change()

    id = ctx.card.id
    assert date_field?(view, "due-date-#{id}")
    assert date_field?(view, "start-date-#{id}")
    assert has_element?(view, "#due-date-#{id}.field-bare")

    # The date once, as the field's words; no due chip repeating it.
    {:ok, cell} = view |> element("#due-#{id}") |> render() |> Floki.parse_fragment()
    assert cell |> Floki.find("[data-role=date-text]") |> Floki.text() == "15 Jan 2030"
    assert Floki.find(cell, ".chip") == []

    view |> form("#due-#{id}", %{"value" => "2030-03-03"}) |> render_change()
    assert Boards.get_card!(id).due_date == ~D[2030-03-03]
    assert has_element?(view, "#due-date-#{id} [data-role=date-text]", "3 Mar 2030")

    view |> form("#start-#{id}", %{"value" => "2030-03-01"}) |> render_change()
    assert Boards.get_card!(id).start_date == ~D[2030-03-01]

    view |> form("#due-#{id}", %{"value" => ""}) |> render_change()
    assert Boards.get_card!(id).due_date == nil
  end

  test "the timeline tray schedules an undated card", %{conn: conn} = ctx do
    loose = card_fixture(ctx.todo, %{"title" => "Loose"})
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/timeline?date=2030-01-15")

    assert date_field?(view, "schedule-date-#{loose.id}")
    assert has_element?(view, "#schedule-date-#{loose.id} [data-role=date-text]", "Set due date")

    view |> form("#schedule-#{loose.id}", %{"value" => "2030-01-18"}) |> render_change()
    assert Boards.get_card!(loose.id).due_date == ~D[2030-01-18]
    refute has_element?(view, "#schedule-date-#{loose.id}")
  end

  test "the calendar's tray schedules too", %{conn: conn} = ctx do
    loose = card_fixture(ctx.todo, %{"title" => "Also loose"})
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/calendar?date=2030-01-15")

    assert date_field?(view, "schedule-date-#{loose.id}")
    view |> form("#schedule-#{loose.id}", %{"value" => "2030-01-20"}) |> render_change()
    assert Boards.get_card!(loose.id).due_date == ~D[2030-01-20]
  end

  test "the board narrative's range is two date fields", %{conn: conn} = ctx do
    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/narrative")

    assert date_field?(view, "narrative-from")
    assert date_field?(view, "narrative-to")
    assert has_element?(view, "#narrative-to [data-role=date-text]", "Today")

    view
    |> form("#swim-config", %{"from" => "2030-01-01", "to" => "2030-01-31"})
    |> render_change()

    assert has_element?(view, "#narrative-from [data-role=date-text]", "1 Jan 2030")
    assert has_element?(view, "#narrative-to-input[value='2030-01-31']")
  end

  describe "Users' paid-up date" do
    setup %{conn: conn} do
      {:ok, _} =
        Settings.complete_setup(%{"admin_email" => "admin@example.com", "signup_mode" => :closed})

      {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
      other = user_fixture("dfe.paid@example.com")
      %{conn: log_in_user(conn, admin), other: other}
    end

    test "saves on a pick, and clears", %{conn: conn, other: other} do
      {:ok, view, _} = live(conn, ~p"/users")
      assert date_field?(view, "paid-until-date-#{other.id}")
      assert has_element?(view, "#paid-until-date-#{other.id} [data-role=date-text]", "Not paid")

      # A pick is a change: no Enter needed, as the raw input wanted.
      view |> form("#paid-until-#{other.id}", %{"paid_until" => "2031-05-06"}) |> render_change()
      assert DateTime.to_date(Accounts.get_user!(other.id).paid_until) == ~D[2031-05-06]

      assert has_element?(
               view,
               "#paid-until-date-#{other.id} [data-role=date-text]",
               "6 May 2031"
             )

      view |> form("#paid-until-#{other.id}", %{"paid_until" => ""}) |> render_change()
      assert Accounts.get_user!(other.id).paid_until == nil
    end

    test "a value that isn't a date is refused", %{conn: conn, other: other} do
      {:ok, view, _} = live(conn, ~p"/users")

      html =
        view
        |> element("#paid-until-#{other.id}")
        |> render_change(%{"user_id" => other.id, "paid_until" => "soon"})

      assert html =~ "That isn&#39;t a date."
      assert Repo.reload!(other).paid_until == nil
    end
  end
end
