defmodule SlipdockWeb.OverviewLiveTest do
  @moduledoc """
  The admin overview page: the totals, a row per person with what they own,
  sorting by a column, and that nobody but an admin gets in.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  setup %{conn: conn} do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => fixture_email("admin@example.com"),
        "signup_mode" => :closed
      })

    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    ordinary = user_fixture("ordinary@example.com")
    %{conn: log_in_user(conn, admin), admin: admin, ordinary: ordinary}
  end

  test "shows the totals and what each person owns", %{conn: conn, ordinary: ordinary} do
    board = board_fixture(%{}, owner: ordinary)
    card_fixture(hd(board.columns))
    card_fixture(hd(board.columns))
    page_fixture(board, %{}, user: ordinary)

    {:ok, view, _html} = live(conn, ~p"/overview")

    totals = view |> element("#overview-totals") |> render()
    assert totals =~ "Accounts"
    assert totals =~ "Wiki pages"

    row = view |> element("#overview-user-#{ordinary.id}") |> render()
    assert row =~ ordinary.email
    # Boards, lists, cards, pages, files, storage, in that order.
    assert row =~
             ~r/>\s*1\s*<.*>\s*#{length(board.columns)}\s*<.*>\s*2\s*<.*>\s*1\s*<.*>\s*0\s*<.*0 bytes/s

    assert row =~ "never"
    assert row =~ Calendar.strftime(ordinary.inserted_at, "%Y-%m-%d")
  end

  test "a column heading sorts by it", %{conn: conn, admin: admin, ordinary: ordinary} do
    board_fixture(%{}, owner: ordinary)
    {:ok, view, _html} = live(conn, ~p"/overview?sort=email")

    html = render(view)
    {a, _} = :binary.match(html, "overview-user-#{admin.id}")
    {o, _} = :binary.match(html, "overview-user-#{ordinary.id}")
    assert a < o

    view |> element("th a", "Boards") |> render_click()
    assert_patch(view, ~p"/overview?sort=boards")

    html = render(view)
    {a, _} = :binary.match(html, "overview-user-#{admin.id}")
    {o, _} = :binary.match(html, "overview-user-#{ordinary.id}")
    assert o < a
    assert view |> element(~s(th[aria-sort="descending"])) |> render() =~ "Boards"
  end

  test "is in the admin's menu", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/overview")
    assert html =~ ~s(href="/overview")
  end

  test "nobody but an admin gets in", %{conn: conn, ordinary: ordinary} do
    assert {:error, {:redirect, %{to: "/"}}} = live(log_in_user(conn, ordinary), ~p"/overview")
  end
end
