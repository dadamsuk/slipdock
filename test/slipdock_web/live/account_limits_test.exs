defmodule SlipdockWeb.AccountLimitsTest do
  @moduledoc """
  What the account page tells somebody about their own limits: the trial, and
  the bars — which stay hidden while the numbers would say nothing useful.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Settings}

  setup %{conn: conn} do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    user = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Theirs"}, owner: user)
    %{conn: log_in_user(conn, user), user: user, column: hd(board.columns)}
  end

  test "a quiet account is told nothing: 3 of 250,000 is noise", %{conn: conn, column: column} do
    for n <- 1..3, do: {:ok, _} = Boards.create_card(column, %{"title" => "Card #{n}"})

    {:ok, _view, html} = live(conn, ~p"/account")

    refute html =~ "What you are using"
    refute html =~ "250000"
  end

  test "a free account with an allowance sees where it stands", %{conn: conn, column: column} do
    {:ok, _} = Settings.update(%{"free_card_limit" => 10})
    for n <- 1..3, do: {:ok, _} = Boards.create_card(column, %{"title" => "Card #{n}"})

    {:ok, _view, html} = live(conn, ~p"/account")

    assert html =~ "What you are using"
    assert html =~ "Cards, pages and files: 3 of 10 used"
    assert html =~ "3 cards"
  end

  test "near the wall it says what to do about it", %{conn: conn, column: column} do
    {:ok, _} = Settings.update(%{"free_card_limit" => 3})
    for n <- 1..3, do: {:ok, _} = Boards.create_card(column, %{"title" => "Card #{n}"})

    {:ok, _view, html} = live(conn, ~p"/account")

    assert html =~ "You have used all of them"
  end

  test "a trial that is running says how long is left", %{conn: conn} do
    {:ok, _} = Settings.update(%{"trial_days" => 30, "trial_enabled" => true})

    {:ok, _view, html} = live(conn, ~p"/account")

    assert html =~ "Free trial"
    assert html =~ "30 day(s) left"
  end

  test "a trial that has ended says so, and says nothing is lost", %{conn: conn, user: user} do
    {:ok, _} = Settings.update(%{"trial_days" => 7, "trial_enabled" => true})

    user
    |> Ecto.Changeset.change(
      inserted_at: DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    {:ok, _view, html} = live(conn, ~p"/account")

    assert html =~ "Your free trial has ended"
    assert html =~ "stays editable"
  end

  test "no trial, nothing said", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/account")
    refute html =~ "Free trial"
  end
end
