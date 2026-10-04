defmodule SlipdockWeb.TermsTest do
  @moduledoc """
  A server's terms: named on the sign-in page, agreed to by signing in — and,
  on a server that has none, never mentioned.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  defp with_terms(attrs \\ %{}) do
    {:ok, _} =
      Settings.complete_setup(
        Map.merge(
          %{
            "admin_email" => "admin@example.com",
            "terms_url" => "https://example.com/terms",
            "privacy_url" => "https://example.com/privacy",
            "terms_version" => "2026-10-02"
          },
          attrs
        )
      )

    :ok
  end

  defp without_terms do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    :ok
  end

  defp sign_in(conn, user), do: get(conn, ~p"/login/#{Accounts.create_sign_in_token(user)}")

  @tag :anonymous
  test "a server with no terms never mentions them", %{conn: conn} do
    without_terms()

    refute Settings.terms?()
    {:ok, _view, html} = live(conn, ~p"/login")
    refute html =~ "you agree"
  end

  test "a link without a version is not terms yet" do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "terms_url" => "https://example.com/terms"
      })

    # Half-filled settings must not start telling people they have agreed to nothing.
    refute Settings.terms?()
    refute Accounts.terms_outstanding?(user_fixture("someone@example.com"))
  end

  @tag :anonymous
  test "the sign-in page says signing in is agreeing, and links both", %{conn: conn} do
    with_terms()

    {:ok, view, _html} = live(conn, ~p"/login")
    terms = view |> element("#login-terms") |> render()
    assert terms =~ "By signing in you agree to these"
    assert terms =~ ~s(href="https://example.com/terms")
    assert terms =~ ~s(href="https://example.com/privacy")
  end

  @tag :anonymous
  test "with no privacy notice, only the terms are linked", %{conn: conn} do
    with_terms(%{"privacy_url" => ""})

    {:ok, view, _html} = live(conn, ~p"/login")
    terms = view |> element("#login-terms") |> render()
    assert terms =~ "https://example.com/terms"
    refute terms =~ "privacy notice"
  end

  @tag :anonymous
  test "signing in records the version, and nothing stands in the way", %{conn: conn} do
    with_terms()
    user = user_fixture("someone@example.com")

    conn = sign_in(conn, user)
    refute redirected_to(conn) == "/terms"

    user = Slipdock.Repo.reload(user)
    assert user.terms_accepted_at
    assert user.terms_version == "2026-10-02"
    assert {:ok, _view, _html} = live(conn |> recycle(), ~p"/")
  end

  @tag :anonymous
  test "a new version is recorded at the next sign-in", %{conn: conn} do
    with_terms()
    user = user_fixture("someone@example.com")
    {:ok, _} = Accounts.accept_terms(user)

    {:ok, _} = Settings.update(%{"terms_version" => "2026-11-01"})
    assert Accounts.terms_outstanding?(Slipdock.Repo.reload(user))

    sign_in(conn, user)
    assert Slipdock.Repo.reload(user).terms_version == "2026-11-01"
  end

  test "a signed-in person is never sent to an interstitial", %{conn: conn} do
    with_terms()
    user = user_fixture("someone@example.com")

    assert {:ok, _view, _html} = live(log_in_user(conn, user), ~p"/")
  end
end
