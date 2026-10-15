defmodule SlipdockWeb.PasskeysLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Accounts.Passkeys
  alias Slipdock.PasskeyAuthenticator, as: Authenticator

  defp add_passkey(user, name) do
    a = Authenticator.new()
    {challenge, _} = Passkeys.registration_challenge(user, "https://slipdock.example.com")
    {:ok, passkey} = Passkeys.register(user, challenge, Authenticator.attest(a, challenge), name)
    passkey
  end

  describe "the sign-in page" do
    @describetag :anonymous

    test "shows the passkey button only once the browser says it can", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/login")

      # The hook's element and its form are always there; the button is not.
      assert html =~ ~s(id="passkey-login")
      assert has_element?(view, ~s(#passkey-login-form[action="/login/passkey"][method="post"]))
      refute has_element?(view, "#passkey-login-button")

      for field <- ~w(id authenticatorData signature clientDataJSON userHandle) do
        assert has_element?(view, ~s(#passkey-login-form input[name="passkey[#{field}]"]))
      end

      view |> element("#passkey-login") |> render_hook("passkey_support", %{"supported" => false})
      refute has_element?(view, "#passkey-login-button")

      view |> element("#passkey-login") |> render_hook("passkey_support", %{"supported" => true})

      assert has_element?(
               view,
               "#passkey-login-button[data-passkey-start]",
               "Sign in with a passkey"
             )
    end

    test "the button goes while a code is being typed", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")
      view |> element("#passkey-login") |> render_hook("passkey_support", %{"supported" => true})

      view
      |> form("#login-form", %{"login" => %{"email" => fixture_email("passkey-code@example.com")}})
      |> render_submit()

      refute has_element?(view, "#passkey-login-button")
    end

    test "a browser-side failure becomes a flash, cut short", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      html =
        view
        |> element("#passkey-login")
        |> render_hook("passkey_failed", %{"message" => "No passkey for this site"})

      assert html =~ "No passkey for this site"

      html =
        view
        |> element("#passkey-login")
        |> render_hook("passkey_failed", %{"message" => String.duplicate("a", 500)})

      refute html =~ String.duplicate("a", 201)
    end
  end

  describe "the account page" do
    test "lists the account's passkeys and nobody else's", %{conn: conn, user: user} do
      add_passkey(user, "Work laptop")
      other = user_fixture("passkey-live-other@example.com")
      add_passkey(other, "Their phone")

      {:ok, view, html} = live(conn, ~p"/account")
      assert html =~ "Passkeys"
      assert has_element?(view, "#passkeys li", "Work laptop")
      assert has_element?(view, "#passkeys li", "not used yet")
      refute html =~ "Their phone"
    end

    test "says so when there are none", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account")
      assert has_element?(view, "#passkeys-empty", "No passkeys yet.")
    end

    test "the add form appears only where the browser can make passkeys", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account")
      refute has_element?(view, "#passkey-add-form")
      refute has_element?(view, "#passkeys-unsupported")

      view |> element("#passkeys") |> render_hook("passkey_support", %{"supported" => false})
      assert has_element?(view, "#passkeys-unsupported")
      refute has_element?(view, "#passkey-add-form")

      view |> element("#passkeys") |> render_hook("passkey_support", %{"supported" => true})
      assert has_element?(view, "#passkey-add-form[data-passkey-add] input[name=name]")
      refute has_element?(view, "#passkeys-unsupported")
    end

    test "once the hook has added one, the list shows it with a flash", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, ~p"/account")

      # The hook posts to the controller, then tells the page.
      add_passkey(user, "Desk key")
      view |> element("#passkeys") |> render_hook("passkey_added", %{"name" => "Desk key"})

      assert has_element?(view, "#passkeys li", "Desk key")
      assert render(view) =~ "Passkey “Desk key” added"
    end

    test "a failure reported by the hook is a flash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account")

      view
      |> element("#passkeys")
      |> render_hook("passkey_failed", %{"message" => "That passkey is already on your account."})

      assert render(view) =~ "That passkey is already on your account."
    end

    test "removes one after asking", %{conn: conn, user: user} do
      passkey = add_passkey(user, "Old phone")
      {:ok, view, _} = live(conn, ~p"/account")

      button = element(view, "#passkey-#{passkey.id} button", "Remove")
      assert render(button) =~ "data-confirm"
      render_click(button)

      refute has_element?(view, "#passkey-#{passkey.id}")
      assert render(view) =~ "Passkey removed"
      assert Passkeys.list(user) == []
    end

    test "cannot remove somebody else's, or a nonsense id", %{conn: conn} do
      other = user_fixture("passkey-live-victim@example.com")
      theirs = add_passkey(other, "Not yours")
      {:ok, view, _} = live(conn, ~p"/account")

      view
      |> element("#passkeys")
      |> render_hook("delete_passkey", %{"id" => to_string(theirs.id)})

      view |> element("#passkeys") |> render_hook("delete_passkey", %{"id" => "nope"})

      assert [%{id: id}] = Passkeys.list(other)
      assert id == theirs.id
      refute render(view) =~ "Passkey removed"
    end

    test "at the cap, the form gives way to a sentence", %{conn: conn, user: user} do
      for i <- 1..Passkeys.max_per_user(), do: add_passkey(user, "Key #{i}")
      {:ok, view, _} = live(conn, ~p"/account")
      view |> element("#passkeys") |> render_hook("passkey_support", %{"supported" => true})

      refute has_element?(view, "#passkey-add-form")
      assert render(view) =~ "the most an account can have"
    end
  end
end
