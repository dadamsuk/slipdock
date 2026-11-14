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

  test "revoking clears the token shown once", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/account/tokens")

    view
    |> form("form[phx-submit=create_token]", %{"label" => "fresh", "scope" => "write"})
    |> render_submit()

    assert has_element?(view, "#new-token")
    {_plain, other} = Accounts.create_api_token(user, "older")

    view |> component_target() |> render_hook("delete_token", %{"id" => to_string(other.id)})
    refute has_element?(view, "#new-token")
    assert [%{label: "fresh"}] = Accounts.list_api_tokens(user)
  end

  describe "revoking an id that isn't one of yours" do
    setup %{user: user} do
      {_plain, mine} = Accounts.create_api_token(user, "mine")
      %{mine: mine}
    end

    test "leaves another account's token working", %{conn: conn, mine: mine} do
      other = user_fixture("stranger@example.com")
      {plain, theirs} = Accounts.create_api_token(other, "theirs")
      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      view |> component_target() |> render_hook("delete_token", %{"id" => to_string(theirs.id)})

      assert Accounts.get_user_by_api_token(plain).id == other.id
      assert [%{id: id}] = Accounts.list_api_tokens(other)
      assert id == theirs.id
      assert Process.alive?(view.pid)
      assert has_element?(view, "#token-#{mine.id}")
    end

    for {name, id} <- [malformed: "12abc", negative: "-1", empty: ""] do
      test "does nothing for a #{name} id", %{conn: conn, user: user, mine: mine} do
        {:ok, view, _html} = live(conn, ~p"/account/tokens")

        view |> component_target() |> render_hook("delete_token", %{"id" => unquote(id)})

        assert Process.alive?(view.pid)
        assert has_element?(view, "#token-#{mine.id}")
        assert [%{id: id}] = Accounts.list_api_tokens(user)
        assert id == mine.id
      end
    end
  end

  describe "the admin scope" do
    test "is not offered to someone who isn't an admin", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      refute has_element?(view, "select[name=scope] option[value=admin]")
      refute render(view) =~ "Administer this server"
    end

    test "submitted by someone who isn't an admin, mints an ordinary token", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      view
      |> component_target()
      |> render_hook("create_token", %{"label" => "forged", "scope" => "admin"})

      assert [token] = Accounts.list_api_tokens(user)
      assert token.label == "forged"
      assert token.scope == "write"
      refute view |> element("#token-#{token.id}") |> render() =~ "admin"
    end

    test "is offered to an admin, and mints an admin token", %{conn: conn, user: user} do
      {:ok, admin} = Accounts.promote(user)
      {:ok, view, _html} = live(conn, ~p"/account/tokens")

      assert has_element?(
               view,
               "select[name=scope] option[value=admin]",
               "Administer this server"
             )

      view
      |> form("form[phx-submit=create_token]", %{"label" => "ops", "scope" => "admin"})
      |> render_submit()

      assert [%{scope: "admin"}] = Accounts.list_api_tokens(admin)
    end
  end

  # The tokens section is a component: a hand-sent event, as a forged one
  # would be, is aimed at the component whose root holds the token form.
  defp component_target(view),
    do: with_target(view, "[data-phx-component]:has(form[phx-submit=create_token])")

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
