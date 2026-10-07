defmodule SlipdockWeb.PosthogTest do
  @moduledoc """
  PostHog analytics: off — no meta tag, no widened policy — until an admin
  fills in a project key, and then on every page.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  setup do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    %{admin: admin}
  end

  defp policy(conn), do: conn |> get(~p"/login") |> get_resp_header("content-security-policy")

  describe "Settings.posthog/0" do
    test "is nil without a key" do
      assert Settings.posthog() == nil
    end

    test "a key with no host is not configured — the region is never guessed" do
      {:ok, _} = Settings.update(%{"posthog_key" => "phc_abc123"})

      # A blank host used to default to the US cloud, which silently sent an EU
      # project's events to the wrong region. It is off instead.
      assert Settings.posthog() == nil
    end

    test "the US cloud loads its script from the US assets host" do
      {:ok, _} =
        Settings.update(%{
          "posthog_key" => "phc_abc123",
          "posthog_host" => "https://us.i.posthog.com"
        })

      assert %{
               key: "phc_abc123",
               host: "https://us.i.posthog.com",
               assets: "https://us-assets.i.posthog.com",
               respect_dnt: true
             } = Settings.posthog()
    end

    test "the EU cloud loads its script from the EU assets host" do
      {:ok, _} =
        Settings.update(%{
          "posthog_key" => "phc_abc",
          "posthog_host" => "https://eu.i.posthog.com/"
        })

      assert %{host: "https://eu.i.posthog.com", assets: "https://eu-assets.i.posthog.com"} =
               Settings.posthog()
    end

    test "respect_dnt is on by default, and the admin can turn it off" do
      {:ok, _} =
        Settings.update(%{
          "posthog_key" => "phc_abc",
          "posthog_host" => "https://eu.i.posthog.com"
        })

      assert %{respect_dnt: true} = Settings.posthog()

      {:ok, _} = Settings.update(%{"posthog_respect_dnt" => "false"})
      assert %{respect_dnt: false} = Settings.posthog()
    end

    test "a proxy of your own serves both" do
      {:ok, _} =
        Settings.update(%{
          "posthog_key" => "phc_abc",
          "posthog_host" => "https://e.example.com/ph"
        })

      assert %{host: "https://e.example.com/ph", assets: "https://e.example.com/ph"} =
               Settings.posthog()
    end

    test "blanking the key turns it off again" do
      {:ok, _} = Settings.update(%{"posthog_key" => "phc_abc"})
      {:ok, settings} = Settings.update(%{"posthog_key" => "   "})

      assert settings.posthog_key == nil
      assert Settings.posthog() == nil
    end

    test "a key that could not be a PostHog key is refused" do
      assert {:error, changeset} = Settings.update(%{"posthog_key" => ~s(phc"><script>)})
      assert %{posthog_key: [_]} = Slipdock.DataCase.errors_on(changeset)
    end

    test "a host that is not a web address is refused" do
      assert {:error, changeset} =
               Settings.update(%{"posthog_key" => "phc_abc", "posthog_host" => "javascript:x"})

      assert %{posthog_host: ["must be an http:// or https:// address"]} =
               Slipdock.DataCase.errors_on(changeset)
    end
  end

  describe "the page" do
    @describetag :anonymous

    test "without a key carries no meta tag and the policy names nobody else", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      refute html =~ ~s(name="posthog")

      assert [policy] = policy(conn)
      refute policy =~ "posthog"
      assert policy =~ "script-src 'self';"
      assert policy =~ "connect-src 'self';"
    end

    test "with a key carries the key and hosts, and the policy allows exactly them", %{
      conn: conn
    } do
      {:ok, _} =
        Settings.update(%{
          "posthog_key" => "phc_abc",
          "posthog_host" => "https://eu.i.posthog.com"
        })

      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ ~s(name="posthog")
      assert html =~ ~s(content="phc_abc")
      assert html =~ ~s(data-host="https://eu.i.posthog.com")
      assert html =~ ~s(data-assets="https://eu-assets.i.posthog.com")
      assert html =~ ~s(data-respect-dnt="true")

      assert [policy] = policy(conn)
      assert policy =~ "script-src 'self' https://eu-assets.i.posthog.com;"

      assert policy =~
               "connect-src 'self' https://eu.i.posthog.com https://eu-assets.i.posthog.com;"
    end

    test "a proxy on its own port is named with that port, and without its path", %{conn: conn} do
      {:ok, _} =
        Settings.update(%{
          "posthog_key" => "phc_abc",
          "posthog_host" => "https://e.example.com:8443/ph"
        })

      assert [policy] = policy(conn)
      assert policy =~ "script-src 'self' https://e.example.com:8443;"
      assert policy =~ "connect-src 'self' https://e.example.com:8443;"
    end
  end

  describe "the Configuration page" do
    test "saves a key and host, and clearing the key turns it off", %{conn: conn, admin: admin} do
      {:ok, view, html} = live(log_in_user(conn, admin), ~p"/config")
      assert html =~ "Product analytics"

      view
      |> form("#analytics-form", %{
        "settings" => %{"posthog_key" => "phc_abc", "posthog_host" => "https://eu.i.posthog.com"}
      })
      |> render_submit()

      assert %{key: "phc_abc", host: "https://eu.i.posthog.com"} = Settings.posthog()

      view
      |> form("#analytics-form", %{"settings" => %{"posthog_key" => ""}})
      |> render_submit()

      assert Settings.posthog() == nil
    end

    test "the Do-Not-Track choice is saved and threaded to the client", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _} = live(log_in_user(conn, admin), ~p"/config")

      view
      |> form("#analytics-form", %{
        "settings" => %{
          "posthog_key" => "phc_abc",
          "posthog_host" => "https://eu.i.posthog.com",
          "posthog_respect_dnt" => "false"
        }
      })
      |> render_submit()

      assert %{respect_dnt: false} = Settings.posthog()

      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ ~s(data-respect-dnt="false")
    end

    test "a bad host is shown as an error and not saved", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(log_in_user(conn, admin), ~p"/config")

      html =
        view
        |> form("#analytics-form", %{
          "settings" => %{"posthog_key" => "phc_abc", "posthog_host" => "ftp://x"}
        })
        |> render_submit()

      assert html =~ "must be an http:// or https:// address"
      assert Settings.posthog() == nil
    end
  end

  describe "the admin API" do
    defp admin_conn(admin) do
      {token, _} = Accounts.create_api_token(admin, "test", scope: "admin")
      build_conn() |> put_req_header("authorization", "Bearer " <> token)
    end

    test "reports analytics off, then on once patched", %{admin: admin} do
      conn = get(admin_conn(admin), ~p"/api/admin/settings")

      assert json_response(conn, 200)["settings"]["analytics"] ==
               %{"posthog_key" => nil, "posthog_host" => nil}

      conn =
        patch(admin_conn(admin), ~p"/api/admin/settings", %{
          "posthog_key" => "phc_abc",
          "posthog_host" => "https://eu.i.posthog.com"
        })

      assert json_response(conn, 200)["settings"]["analytics"] ==
               %{"posthog_key" => "phc_abc", "posthog_host" => "https://eu.i.posthog.com"}

      assert Settings.posthog().key == "phc_abc"
    end
  end
end
