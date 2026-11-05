defmodule SlipdockWeb.OneDateFormatLiveTest do
  @moduledoc """
  The swept pages write dates through `SlipdockWeb.Dates`, in the reader's
  own timezone, and a relative time carries the exact one in its `title`
  (#1719).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Settings}

  # 23:30 UTC on 18 Nov 2025 is 12:30 on the 19th in Auckland.
  @late ~U[2025-11-18 23:30:00Z]

  defp in_auckland(user) do
    Repo.update!(Ecto.Changeset.change(user, timezone: "Pacific/Auckland"))
  end

  test "the card back's created line is relative, exact in the reader's zone", %{conn: conn} do
    user = in_auckland(user_fixture("odf.card@example.com"))
    board = board_fixture(%{}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Dated"})
    Repo.update!(Ecto.Changeset.change(card, inserted_at: @late))

    {:ok, view, _} = live(log_in_user(conn, user), ~p"/boards/#{board}/cards/#{card.id}")

    assert has_element?(view, "#card-created-at[title='19 Nov 2025, 12:30 NZDT']", "19 Nov 2025")
    assert has_element?(view, "#card-created-at[datetime='2025-11-18T23:30:00Z']")
  end

  test "activity says how long ago, with the exact time in the title", %{conn: conn} do
    user = user_fixture("odf.activity@example.com")
    board = board_fixture(%{}, owner: user)
    card_fixture(hd(board.columns), %{"title" => "Something happened"})

    {:ok, view, _} = live(log_in_user(conn, user), ~p"/boards/#{board}/activity")

    assert has_element?(view, "time[data-role=timestamp][title*='UTC']", "just now")
    refute render(view) =~ ~r/>\s*\d+[mhd] ago\s*</
  end

  test "Users and Overview write dates in the admin's zone, never ISO", %{conn: conn} do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "signup_mode" => :closed})

    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    admin = in_auckland(admin)
    other = user_fixture("odf.other@example.com")
    Repo.update!(Ecto.Changeset.change(other, last_signed_in_at: @late, inserted_at: @late))
    conn = log_in_user(conn, admin)

    {:ok, users, html} = live(conn, ~p"/users")
    assert has_element?(users, "#last-seen-#{other.id}[title='19 Nov 2025, 12:30 NZDT']")
    assert has_element?(users, "#last-seen-#{other.id}", "19 Nov 2025")
    refute html =~ ~r/>\s*\d{4}-\d\d-\d\dT\d\d:\d\d/

    {:ok, overview, _} = live(conn, ~p"/overview")
    row = overview |> element("#overview-user-#{other.id}") |> render()
    assert row =~ "19 Nov 2025"
    refute row =~ ~r/>\s*\d{4}-\d\d-\d\d\s*</
  end
end
