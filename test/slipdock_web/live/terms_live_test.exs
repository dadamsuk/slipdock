defmodule SlipdockWeb.TermsLiveTest do
  @moduledoc """
  Agreeing to a server's terms — and, on a server that has none, never being
  asked.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  defp with_terms(version \\ "2026-10-02") do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "terms_url" => "https://example.com/terms",
        "privacy_url" => "https://example.com/privacy",
        "terms_version" => version
      })

    :ok
  end

  defp without_terms do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    :ok
  end

  setup %{conn: conn} do
    user = user_fixture("someone@example.com")
    %{conn: log_in_user(conn, user), user: user}
  end

  test "a server with no terms never mentions them", %{conn: conn, user: user} do
    without_terms()

    refute Settings.terms?()
    refute Accounts.terms_outstanding?(user)
    assert {:ok, _view, _html} = live(conn, ~p"/")
  end

  test "a link without a version is not terms yet", %{user: user} do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "terms_url" => "https://example.com/terms"
      })

    # Half-filled settings must not start asking people to agree to nothing.
    refute Settings.terms?()
    refute Accounts.terms_outstanding?(user)
  end

  test "everything else sends you to the terms until you agree", %{conn: conn} do
    with_terms()

    assert {:error, {:redirect, %{to: "/terms"}}} = live(conn, ~p"/")
    assert {:error, {:redirect, %{to: "/terms"}}} = live(conn, ~p"/work")
  end

  test "agreeing records the version, and lets you through", %{conn: conn, user: user} do
    with_terms()

    {:ok, view, html} = live(conn, ~p"/terms")
    assert html =~ "https://example.com/terms"
    assert html =~ "https://example.com/privacy"

    view |> element("button", "I agree") |> render_click()

    user = Slipdock.Repo.reload(user)
    assert user.terms_accepted_at
    assert user.terms_version == "2026-10-02"
    refute Accounts.terms_outstanding?(user)

    assert {:ok, _view, _html} = live(conn, ~p"/")
  end

  test "changing the version asks again, and says so", %{conn: conn, user: user} do
    with_terms()
    {:ok, _} = Accounts.accept_terms(user)
    refute Accounts.terms_outstanding?(Slipdock.Repo.reload(user))

    {:ok, _} = Settings.update(%{"terms_version" => "2026-11-01"})

    assert Accounts.terms_outstanding?(Slipdock.Repo.reload(user))
    {:ok, _view, html} = live(conn, ~p"/terms")
    assert html =~ "have changed since you last agreed"
  end

  test "an admin cannot skip their own terms", %{conn: conn} do
    with_terms()
    admin = user_fixture("admin@example.com")
    {:ok, admin} = Accounts.promote(admin)

    assert {:error, {:redirect, %{to: "/terms"}}} =
             live(log_in_user(conn, admin), ~p"/config")
  end

  test "the page offers a way out that touches nothing", %{conn: conn} do
    with_terms()
    {:ok, _view, html} = live(conn, ~p"/terms")

    assert html =~ "Sign out"
    assert html =~ "nothing of yours is touched"
  end
end
