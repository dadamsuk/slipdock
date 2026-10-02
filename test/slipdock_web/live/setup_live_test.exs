defmodule SlipdockWeb.SetupLiveTest do
  @moduledoc """
  The first-run wizard: the gate around it, the token that stops a passer-by
  claiming the server, and the three steps.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Slipdock.{Accounts, Settings}

  setup do
    previous = Application.get_env(:slipdock, :settings)
    Application.put_env(:slipdock, :settings, setup_completed: false)
    on_exit(fn -> Application.put_env(:slipdock, :settings, previous) end)

    fallback =
      Path.join(
        System.tmp_dir!(),
        "slipdock-test-sign-in-#{System.unique_integer([:positive])}.log"
      )

    Application.put_env(:slipdock, :login_fallback_path, fallback)

    on_exit(fn ->
      Application.delete_env(:slipdock, :login_fallback_path)
      File.rm(fallback)
    end)

    %{token: Settings.ensure_setup_token(), fallback: fallback}
  end

  describe "the gate" do
    test "a set-up server has no /setup at all", %{conn: conn} do
      {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})

      # 404 rather than a redirect: a redirect would tell a stranger there is an
      # administrative corner here to go looking for.
      assert conn |> get(~p"/setup") |> response(404)
    end

    test "an unclaimed server sends every other page to the wizard", %{conn: conn} do
      assert conn |> get(~p"/") |> redirected_to() == "/setup"
      assert conn |> get(~p"/work") |> redirected_to() == "/setup"
    end

    @tag :anonymous
    test "even signing in goes to the wizard first", %{conn: conn} do
      # There is nobody to sign in as yet, and the wizard is the only way a
      # server gets claimed. Two doors that can both claim one is worse than
      # either on its own.
      assert conn |> get(~p"/login") |> redirected_to() == "/setup"
    end

    @tag :anonymous
    test "assets still load, or the wizard would have no stylesheet", %{conn: conn} do
      refute conn |> get("/assets/css/app.css") |> redirected_to_setup?()
    end

    defp redirected_to_setup?(conn), do: conn.status == 302
  end

  describe "the setup token" do
    test "without it the wizard asks for it and goes no further", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/setup")

      assert html =~ "The setup token, please"
      refute html =~ "Who can register"
      assert has_element?(view, "#setup-token-form")
    end

    test "a wrong one is refused", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/setup")

      html =
        view |> form("#setup-token-form", %{"setup" => %{"token" => "nope"}}) |> render_submit()

      assert html =~ "not the setup token"
      assert has_element?(view, "#setup-token-form")
    end

    test "the right one in the URL skips straight to step one", %{conn: conn, token: token} do
      {:ok, _view, html} = live(conn, ~p"/setup?token=#{token}")

      assert html =~ "Who can register"
      refute html =~ "The setup token, please"
    end

    test "the right one typed in also works", %{conn: conn, token: token} do
      {:ok, view, _} = live(conn, ~p"/setup")

      html =
        view |> form("#setup-token-form", %{"setup" => %{"token" => token}}) |> render_submit()

      assert html =~ "Who can register"
    end
  end

  describe "the three steps" do
    setup %{conn: conn, token: token} do
      {:ok, view, _} = live(conn, ~p"/setup?token=#{token}")
      %{view: view}
    end

    test "nothing is written until the last step", %{view: view} do
      view
      |> form("#setup-mode-form", %{
        "settings" => %{"signup_mode" => "approval", "free_card_limit" => "20"}
      })
      |> render_submit()

      # Collected, not saved: an abandoned wizard must not leave a
      # half-configured server behind.
      assert Settings.signup_mode() != :approval
      refute Settings.setup_complete?()
    end

    test "going back shows the answers already given", %{view: view} do
      view
      |> form("#setup-mode-form", %{
        "settings" => %{"signup_mode" => "approval", "free_card_limit" => "20"}
      })
      |> render_submit()

      html = view |> element("button", "Back") |> render_click()

      # The radio somebody chose is still chosen, and the limit they typed is
      # still there. A wizard that forgets your answers when you step back is
      # worse than one with no Back button.
      assert html =~ ~s(value="approval" checked)
      assert html =~ ~s(value="20")
    end

    test "the safe mode is the one preselected" do
      # Not a server that starts collecting accounts because nobody touched a
      # radio button.
      assert render(
               elem(
                 live(
                   Phoenix.ConnTest.build_conn(),
                   "/setup?token=#{Settings.ensure_setup_token()}"
                 ),
                 1
               )
             ) =~ ~s(value="closed" checked)
    end

    test "mail cannot be saved without a test message that worked", %{view: view} do
      view
      |> form("#setup-mode-form", %{"settings" => %{"signup_mode" => "closed"}})
      |> render_submit()

      html =
        view
        |> form("#setup-mail-form", %{
          "settings" => %{"smtp_host" => "smtp.example.com", "smtp_from_email" => "m@example.com"}
        })
        |> render_submit()

      assert html =~ "Send a test message that arrives"
      # Still on the mail step.
      assert has_element?(view, "#setup-mail-form")
    end

    test "a successful test message unlocks it", %{view: view} do
      view
      |> form("#setup-mode-form", %{"settings" => %{"signup_mode" => "closed"}})
      |> render_submit()

      # The test send is a submit with its own button value, so the values just
      # typed travel with it.
      html =
        view
        |> form("#setup-mail-form", %{
          "settings" => %{
            "smtp_host" => "smtp.example.com",
            "smtp_from_email" => "m@example.com",
            "test_to" => "admin@example.com"
          }
        })
        |> render_submit(%{"step_action" => "test"})

      assert html =~ "test message went out"
      assert_email_sent(subject: "Slipdock can send mail")
    end

    test "mail can be skipped, and then the fallback file is named", %{view: view, fallback: path} do
      view
      |> form("#setup-mode-form", %{"settings" => %{"signup_mode" => "closed"}})
      |> render_submit()

      html = view |> element("button", "Skip — no mail server") |> render_click()

      assert html =~ "No mail server, so your sign-in code goes to a file"
      assert html =~ path
    end

    test "finishing claims the server, makes the admin, and closes the page", %{
      view: view,
      fallback: path
    } do
      view
      |> form("#setup-mode-form", %{
        "settings" => %{"signup_mode" => "allowlist", "free_card_limit" => "20"}
      })
      |> render_submit()

      view |> element("button", "Skip — no mail server") |> render_click()

      html =
        view
        |> form("#setup-admin-form", %{"settings" => %{"admin_email" => "owner@example.com"}})
        |> render_submit()

      assert html =~ "This server is yours"

      # Everything collected along the way is saved in one go, at the end.
      assert Settings.setup_complete?()
      assert Settings.signup_mode() == :allowlist
      assert Settings.free_card_limit() == 20
      assert Settings.get().admin_email == "owner@example.com"

      owner = Accounts.get_user_by_email("owner@example.com")
      assert Accounts.admin?(owner)

      # With no mail server, the way in is the file the screen pointed at.
      assert File.read!(path) =~ "owner@example.com"
      assert html =~ path
    end
  end
end
