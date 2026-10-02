defmodule SlipdockWeb.LoginWordingTest do
  @moduledoc """
  What the sign-in page says under each registration mode.

  The rule it must not break: nothing on this page may reveal whether a
  particular address has an account here. What kind of server this is may be
  said, because that is public anyway and saves people guessing.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Settings

  defp set_up(attrs) do
    {:ok, _} =
      Settings.complete_setup(Map.merge(%{"admin_email" => "admin@example.com"}, attrs))

    :ok
  end

  defp mail, do: %{"smtp_host" => "smtp.example.com", "smtp_from_email" => "mail@example.com"}

  describe "the strapline" do
    @tag :anonymous
    test "an unclaimed server is honest about being unclaimed", %{conn: conn} do
      previous = Application.get_env(:slipdock, :settings)
      Application.put_env(:slipdock, :settings, setup_completed: false)
      on_exit(fn -> Application.put_env(:slipdock, :settings, previous) end)

      # /login redirects to the wizard on an unclaimed server, so this is about
      # the stance the page would report, not a page anybody reaches.
      assert Slipdock.Accounts.signup_stance() == :unclaimed
    end

    @tag :anonymous
    test "with no mail, it says where the code actually goes", %{conn: conn} do
      set_up(%{"signup_mode" => :open})

      {:ok, _view, html} = live(conn, ~p"/login")
      assert html =~ "write it where you can read it"
    end

    @tag :anonymous
    test "with mail, it promises an email", %{conn: conn} do
      set_up(Map.put(mail(), "signup_mode", :open))

      {:ok, _view, html} = live(conn, ~p"/login")
      assert html =~ "email you a link and a code"
    end
  end

  describe "approval mode" do
    setup do
      set_up(Map.put(mail(), "signup_mode", :approval))
      {:ok, _} = Slipdock.Accounts.promote(user_fixture("admin@example.com"))
      :ok
    end

    @tag :anonymous
    test "offers a way to ask, because silence looks like a bug", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/login")

      assert html =~ "an admin approves each one"
      assert has_element?(view, "#signup-request-form")
    end

    @tag :anonymous
    test "says plainly that the request is waiting on a person", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      html =
        view
        |> form("#signup-request-form", %{
          "request" => %{"email" => "hopeful@example.com", "note" => ""}
        })
        |> render_submit()

      assert html =~ "Your request is with the admin"
    end

    @tag :anonymous
    test "a rejected address is told the same thing as a fresh one", %{conn: conn} do
      admin = Slipdock.Accounts.get_user_by_email("admin@example.com")
      {:ok, request} = Slipdock.Accounts.request_signup("nuisance@example.com")
      {:ok, _} = Slipdock.Accounts.reject_signup(request, admin)

      {:ok, view, _} = live(conn, ~p"/login")

      html =
        view
        |> form("#signup-request-form", %{
          "request" => %{"email" => "nuisance@example.com", "note" => ""}
        })
        |> render_submit()

      # Kinder to say "you were turned down", but that confirms the address to
      # anybody who types it.
      assert html =~ "Your request is with the admin"
    end
  end

  describe "the other modes" do
    @tag :anonymous
    test "closed offers no way to ask", %{conn: conn} do
      set_up(%{"signup_mode" => :closed})

      {:ok, view, _html} = live(conn, ~p"/login")
      refute has_element?(view, "#signup-request-form")
    end

    @tag :anonymous
    test "a refused address gets exactly what an accepted one gets", %{conn: conn} do
      set_up(Map.put(mail(), "signup_mode", :closed))
      user_fixture("member@example.com")

      {:ok, view, _} = live(conn, ~p"/login")

      refused =
        view
        |> form("#login-form", %{"login" => %{"email" => "stranger@example.com"}})
        |> render_submit()

      {:ok, view, _} = live(conn, ~p"/login")

      accepted =
        view
        |> form("#login-form", %{"login" => %{"email" => "member@example.com"}})
        |> render_submit()

      # Same screen, same words, different address — otherwise the page answers
      # "does this person have an account here?" for anybody who asks.
      assert refused =~ "Check your email"
      assert accepted =~ "Check your email"
      refute Slipdock.Accounts.get_user_by_email("stranger@example.com")
    end
  end
end
