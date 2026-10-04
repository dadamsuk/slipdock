defmodule SlipdockWeb.ConfigLiveTest do
  @moduledoc """
  The Configuration page, and above all what it refuses. An admin page that
  lets you brick your own instance is worse than no admin page.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  defp set_up(attrs \\ %{}) do
    {:ok, _} =
      Settings.complete_setup(
        Map.merge(%{"admin_email" => "admin@example.com", "signup_mode" => :closed}, attrs)
      )

    :ok
  end

  setup %{conn: conn} do
    set_up()
    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    ordinary = user_fixture("ordinary@example.com")
    %{conn: log_in_user(conn, admin), admin: admin, ordinary: ordinary}
  end

  describe "who can get in" do
    test "an admin can", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/config")
      assert html =~ "Who can register"
    end

    test "an ordinary user is sent away without being told there is anything here", %{
      conn: conn,
      ordinary: ordinary
    } do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(log_in_user(conn, ordinary), ~p"/config")
    end
  end

  describe "settings" do
    test "changing the mode says it does not remove anybody", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/config")
      assert html =~ "does not remove anybody"

      view
      |> form("#admin-settings-form", %{"settings" => %{"signup_mode" => "open"}})
      |> render_submit()

      assert Settings.signup_mode() == :open
    end

    test "the limits are shown with their numbers and switches", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/config")

      assert html =~ "Limits for everybody"
      assert html =~ "Boards one person may own"
      assert html =~ "Free accounts expire"
      assert html =~ ~s(value="1000")
      assert html =~ ~s(value="250000")
      assert html =~ ~s(value="10240")
    end

    test "a limit can be changed and switched off", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      view
      |> form("#admin-settings-form", %{
        "settings" => %{
          "signup_mode" => "closed",
          "board_limit" => "50",
          "board_limit_enabled" => "true",
          "storage_limit_enabled" => "false",
          "trial_days" => "14",
          "trial_enabled" => "true"
        }
      })
      |> render_submit()

      assert Settings.board_limit() == 50
      # Switched off, but the number it had is still there to switch back on.
      assert Settings.storage_limit_bytes() == nil
      assert Settings.storage_limit_mb() == 10_240
      assert Settings.trial_days() == 14
    end

    test "clearing a limit's box leaves the number alone rather than saving nothing", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/config")

      # A blank number field reads as "no change" (Ecto's empty values), not as
      # "a limit of nothing" — which is what the switch is for. The page then
      # redraws with the number still in it.
      html =
        view
        |> form("#admin-settings-form", %{
          "settings" => %{
            "signup_mode" => "closed",
            "item_limit" => "",
            "item_limit_enabled" => "true"
          }
        })
        |> render_submit()

      assert Settings.item_limit() == 250_000
      assert html =~ ~s(value="250000")
    end

    test "the allowlist editor appears only when it is the mode", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")
      refute has_element?(view, "#allow-form")

      view
      |> form("#admin-settings-form", %{"settings" => %{"signup_mode" => "allowlist"}})
      |> render_submit()

      assert has_element?(view, "#allow-form")
    end

    test "entries can be added and removed", %{conn: conn, admin: admin} do
      {:ok, _} = Settings.update(%{"signup_mode" => :allowlist})
      {:ok, view, _} = live(conn, ~p"/config")

      view |> form("#allow-form", %{"allow" => %{"entry" => "example.org"}}) |> render_submit()

      assert [entry] = Settings.list_allowlist()
      assert entry.entry == "example.org"
      assert entry.added_by_id == admin.id

      view |> element("button[phx-value-id='#{entry.id}']") |> render_click()
      assert Settings.list_allowlist() == []
    end

    test "the admin's own address cannot be smuggled in through the settings form", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      # The form has no such field, so this is the crafted-event version: an
      # admin address changed without the new one proving it can receive mail
      # is a silent lock-out waiting to happen.
      render_submit(view, "save-settings", %{
        "settings" => %{"signup_mode" => "closed", "admin_email" => "hijack@example.com"}
      })

      assert Settings.get().admin_email == "admin@example.com"
    end
  end

  describe "fields a form does not show" do
    test "the settings form cannot change the mail server without a test", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      render_submit(view, "save-settings", %{
        "settings" => %{"signup_mode" => "closed", "smtp_host" => "evil.example.com"}
      })

      assert Settings.get().smtp_host in [nil, ""]
    end

    test "the mail form cannot change the admin address or anything else", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config/mail")

      render_submit(view, "mail", %{
        "settings" => %{"admin_email" => "hijack@example.com", "signup_mode" => "open"}
      })

      settings = Settings.get()
      assert settings.admin_email == "admin@example.com"
      assert settings.signup_mode == :closed
    end

    test "terms links must be web addresses", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      render_submit(view, "save-settings", %{
        "settings" => %{"terms_url" => "javascript:alert(1)", "privacy_url" => "https://x.test/p"}
      })

      assert Settings.get().terms_url == nil
    end
  end

  describe "mail" do
    test "will not save a change without a test message that worked", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config/mail")

      html =
        view
        |> form("#admin-mail-form", %{
          "settings" => %{"smtp_host" => "smtp.example.com", "smtp_from_email" => "m@example.com"}
        })
        |> render_submit(%{"step_action" => "save"})

      assert html =~ "locked out"
      refute Settings.smtp_configured?()
    end

    test "saves once a test has gone out", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config/mail")

      params = %{
        "settings" => %{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "m@example.com",
          "test_to" => "admin@example.com"
        }
      }

      view |> form("#admin-mail-form", params) |> render_submit(%{"step_action" => "test"})
      view |> form("#admin-mail-form", params) |> render_submit(%{"step_action" => "save"})

      assert Settings.smtp_configured?()
    end

    test "keeps what was typed through the test send, and saves that", %{conn: conn} do
      # The regression: the form used to be rendered from the stored settings,
      # so the test send put the old values back into the fields and the save
      # that followed stored those instead of what the admin had typed.
      {:ok, view, _} = live(conn, ~p"/config/mail")

      view
      |> form("#admin-mail-form", %{
        "settings" => %{
          "smtp_host" => "smtp.new.example.com",
          "smtp_port" => "2525",
          "smtp_from_email" => "post@example.com",
          "test_to" => "admin@example.com"
        }
      })
      |> render_submit(%{"step_action" => "test"})

      # No params: whatever the page is now showing is what a browser sends.
      view |> form("#admin-mail-form") |> render_submit(%{"step_action" => "save"})

      settings = Settings.get()
      assert settings.smtp_host == "smtp.new.example.com"
      assert settings.smtp_port == 2525
      assert settings.smtp_from_email == "post@example.com"
      assert settings.smtp_verified_at
    end

    test "asks for another test when a field changes after one", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config/mail")

      tested = %{
        "settings" => %{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "m@example.com",
          "test_to" => "admin@example.com"
        }
      }

      view |> form("#admin-mail-form", tested) |> render_submit(%{"step_action" => "test"})

      html =
        view
        |> form(
          "#admin-mail-form",
          put_in(tested, ["settings", "smtp_host"], "smtp.other.example")
        )
        |> render_submit(%{"step_action" => "save"})

      assert html =~ "locked out"
      refute Settings.smtp_configured?()
    end

    test "says where sign-in codes go, and that it is a back door", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/config/mail")
      assert html =~ "can sign in as anybody"
    end
  end

  describe "which build is running" do
    test "the commit and the build time are at the top of the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/config")

      assert html =~ "Running build"
      assert html =~ Slipdock.Build.short_sha()
      assert html =~ Slipdock.Build.built_at_string()
    end

    test "it is there on the mail tab too, since it is the whole page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/config/mail")
      assert html =~ Slipdock.Build.short_sha()
    end
  end
end
