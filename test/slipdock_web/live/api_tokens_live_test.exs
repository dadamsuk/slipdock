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

    refute view |> element("button[phx-click=dismiss_token]") |> render_click() =~
             "Copy this token now"
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

    view |> element("#token-#{token.id} button[phx-click=delete_token]") |> render_click()
    assert Accounts.list_api_tokens(user) == []
  end

  describe "a connection made with OAuth" do
    setup %{user: user} do
      {:ok, client} =
        Slipdock.OAuth.register_client(%{
          client_name: "Claude",
          redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]
        })

      {_access, row} = Accounts.create_api_token(user, "Claude", scope: "write")
      past = DateTime.utc_now(:second) |> DateTime.add(-60, :second)

      row =
        row
        |> Ecto.Changeset.change(
          oauth_client_id: client.id,
          # The hourly access token has lapsed; the connection has not.
          expires_at: past,
          refresh_expires_at: DateTime.utc_now(:second) |> DateTime.add(90, :day)
        )
        |> Slipdock.Repo.update!()

      %{row: row}
    end

    test "is shown as a connected app that renews itself, not as expired", %{
      conn: conn,
      row: row
    } do
      {:ok, view, _html} = live(conn, ~p"/account/tokens")
      html = view |> element("#token-#{row.id}") |> render()

      assert html =~ "connected app"
      assert html =~ "renews until"
      refute html =~ "expired"
    end

    test "is shown as expired once its refresh token has lapsed", %{conn: conn, row: row} do
      row
      |> Ecto.Changeset.change(
        refresh_expires_at: DateTime.utc_now(:second) |> DateTime.add(-1, :day)
      )
      |> Slipdock.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/account/tokens")
      html = view |> element("#token-#{row.id}") |> render()

      assert html =~ "expired"
      refute html =~ "renews until"
    end
  end
end
