defmodule SlipdockWeb.ApiTokensLiveTest do
  @moduledoc """
  The Account page's API tokens section: minting one with a scope and an
  expiry, and showing enough about it afterwards to decide whether to revoke.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Accounts

  setup %{conn: conn} do
    user = user_fixture("owner@example.com")
    %{conn: log_in_user(conn, user), user: user}
  end

  test "a token is created read/write and never expiring by default", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/account/tokens")

    view
    |> form("form[phx-submit=create_token]", %{
      "label" => "laptop",
      "scope" => "write",
      "expires_in_days" => ""
    })
    |> render_submit()

    assert [token] = Accounts.list_api_tokens(user)
    assert token.label == "laptop"
    assert token.scope == "write"
    assert is_nil(token.expires_at)

    html = render(view)
    assert html =~ "read/write"
    assert html =~ "never expires"
  end

  test "a read-only token with an expiry is created and shown as such", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/account/tokens")

    view
    |> form("form[phx-submit=create_token]", %{
      "label" => "agent",
      "scope" => "read",
      "expires_in_days" => "90"
    })
    |> render_submit()

    assert [token] = Accounts.list_api_tokens(user)
    assert token.scope == "read"
    assert token.expires_at
    assert DateTime.diff(token.expires_at, DateTime.utc_now(), :day) in 89..90

    html = render(view)
    assert html =~ "read only"
    assert html =~ "expires"
  end

  test "the plaintext token is shown once, and only once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/account/tokens")

    html =
      view
      |> form("form[phx-submit=create_token]", %{"label" => "once", "scope" => "write"})
      |> render_submit()

    assert html =~ "Copy this token now"
    refute render_click(view, "dismiss_token") =~ "Copy this token now"
  end

  test "an expired token is labelled expired rather than quietly listed", %{
    conn: conn,
    user: user
  } do
    Accounts.create_api_token(user, "stale",
      expires_at: DateTime.utc_now(:second) |> DateTime.add(-1, :day)
    )

    {:ok, _view, html} = live(conn, ~p"/account/tokens")
    assert html =~ "expired"
  end

  test "revoking removes it", %{conn: conn, user: user} do
    {_plain, token} = Accounts.create_api_token(user, "doomed")
    {:ok, view, _html} = live(conn, ~p"/account/tokens")

    render_click(view, "delete_token", %{"id" => to_string(token.id)})
    assert Accounts.list_api_tokens(user) == []
  end
end
