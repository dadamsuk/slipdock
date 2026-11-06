defmodule SlipdockWeb.AdminNavTest do
  @moduledoc """
  The Admin area (#1738): every admin page in the settings layout, with one
  Admin nav (`SlipdockWeb.AdminNav`) marking the page you're on, the
  section's name as its heading, and the running build in the nav's footer.
  The old tablists of Users and Configuration are gone: their parts are nav
  entries. Anybody but an admin is still turned away, on every route.

  One test per route, generated, rather than one long test walking them all
  (a long one timed out in CI).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings, Tools}
  alias SlipdockWeb.AdminNav

  # {path, nav key, heading, content width}
  @routes [
    {"/users", :people, "People", "wide"},
    {"/users/signups", :signups, "Sign-ups", "wide"},
    {"/overview", :overview, "Overview", "wide"},
    {"/config", :server, "Server", "narrow"},
    {"/config/mail", :mail, "Email", "narrow"},
    {"/config/ai", :ai, "AI", "narrow"},
    {"/admin/tools", :tools, "Tools", "wide"}
  ]

  @entries ~w(/users /users/signups /overview /config /config/mail /config/ai /admin/tools)

  defp admin_conn(conn, mode) do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => fixture_email("admin@example.com"),
        # Approval needs mail, to tell an admin that somebody is waiting.
        "smtp_host" => "smtp.example.com",
        "smtp_from_email" => fixture_email("mail@example.com"),
        "signup_mode" => mode
      })

    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    log_in_user(conn, admin)
  end

  describe "an admin" do
    setup %{conn: conn}, do: %{conn: admin_conn(conn, :approval)}

    for {path, key, heading, width} <- @routes do
      test "#{path} is #{heading} in the Admin area, marked in the nav", %{conn: conn} do
        {:ok, view, html} = live(conn, unquote(path))

        assert has_element?(view, "[data-page-width=full] h1", "Admin")
        assert has_element?(view, "#admin[data-settings-layout]")

        # Every entry, in order, in the side nav and the phone's picker.
        for list <- ["#admin-nav", "#admin-picker nav"] do
          hrefs =
            html
            |> LazyHTML.from_fragment()
            |> LazyHTML.query("#{list} a")
            |> LazyHTML.attribute("href")

          assert hrefs == @entries, "#{unquote(path)}: #{list} lists #{inspect(hrefs)}"
        end

        # Only this page is current, in both lists.
        current = ~s(a[aria-current=page])
        assert has_element?(view, ~s(#admin-nav a[href="#{unquote(path)}"][aria-current=page]))
        assert has_element?(view, ~s(#admin-picker a[href="#{unquote(path)}"][aria-current=page]))

        assert html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#admin-nav #{current}")
               |> Enum.count() ==
                 1

        assert has_element?(
                 view,
                 "#admin-content[data-content-width=#{unquote(width)}] [data-role=settings-section-title]",
                 unquote(heading)
               )

        assert has_element?(view, "#admin-picker summary", unquote(heading))
        assert page_title(view) =~ unquote(heading)
        assert AdminNav.label(unquote(key)) == unquote(heading)

        # The build strip is in the nav's footer, not the page's body.
        assert has_element?(
                 view,
                 "#admin-nav [data-role=settings-nav-footer] [data-role=build-info]",
                 Slipdock.Build.short_sha()
               )

        assert has_element?(view, "#admin-nav [data-role=build-info]", "Running build")
        refute has_element?(view, "#admin-content [data-role=build-info]")
        refute has_element?(view, "#build-info")

        # No hand-made tablist is left.
        refute has_element?(view, "[role=tablist]")
        refute has_element?(view, ".tabs-box")
      end
    end

    test "the nav is grouped: Accounts, Configuration and Review", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/overview")
      groups = view |> render() |> LazyHTML.from_fragment()

      assert groups
             |> LazyHTML.query("#admin-nav [data-role=settings-group]")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) ==
               ["Accounts", "Configuration", "Review"]
    end

    test "a section's entry leads to that section", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      {:ok, view, _} =
        view
        |> element("#admin-nav a[href='/config/mail']")
        |> render_click()
        |> follow_redirect(conn, ~p"/config/mail")

      assert has_element?(view, "#admin-nav a[href='/config/mail'][aria-current=page]")
      assert has_element?(view, "#admin-content [data-role=settings-section-title]", "Email")
      assert has_element?(view, "#admin-mail-form")
    end

    test "Tools carries the count of versions waiting to be listed", %{conn: conn, user: user} do
      refute has_element?(
               elem(live(conn, ~p"/overview"), 1),
               "#admin-nav a[href='/admin/tools'] [data-role=settings-badge]"
             )

      Slipdock.TestConfig.own_uploads_dir()
      name = Slipdock.ToolPackages.unique_name()
      {:ok, version} = Tools.publish(user, Slipdock.ToolPackages.package(name))
      {:ok, _} = Tools.request_listing(user, version)

      {:ok, view, _} = live(conn, ~p"/overview")

      assert has_element?(
               view,
               "#admin-nav a[href='/admin/tools'] [data-role=settings-badge]",
               "1"
             )
    end

    test "Sign-ups carries the count waiting, and none when nobody is", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")
      assert has_element?(view, "#admin-nav a[href='/users/signups']")
      refute has_element?(view, "#admin-nav a[href='/users/signups'] [data-role=settings-badge]")

      {:ok, _} = Accounts.request_signup(fixture_email("hopeful@example.com"), note: "Hi")
      {:ok, view, _} = live(conn, ~p"/config")

      assert has_element?(
               view,
               "#admin-nav a[href='/users/signups'] [data-role=settings-badge]",
               "1"
             )
    end
  end

  describe "an admin when sign-up isn't by approval" do
    setup %{conn: conn}, do: %{conn: admin_conn(conn, :closed)}

    test "Sign-ups is left out of the nav on the other pages", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/users")
      refute has_element?(view, "#admin-nav a[href='/users/signups']")
      refute has_element?(view, "#admin-picker a[href='/users/signups']")
      assert has_element?(view, "#admin-nav a[href='/users'][aria-current=page]")
    end

    test "but kept on its own page, so the current page is always listed", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/users/signups")
      assert has_element?(view, "#admin-nav a[href='/users/signups'][aria-current=page]")
    end
  end

  describe "anybody else" do
    for {path, _, _, _} <- @routes do
      test "an ordinary person is refused #{path}", %{conn: conn} do
        conn = log_in_user(conn, user_fixture("ordinary-#{unquote(path)}@example.com"))
        assert {:error, {:redirect, _}} = live(conn, unquote(path))
      end

      test "a signed-out visitor is sent to sign in from #{path}" do
        assert {:error, {:redirect, %{to: to}}} = live(build_conn(), unquote(path))
        assert to =~ "/login" or to =~ "/sign"
      end
    end
  end

  describe "AdminNav" do
    test "keys and labels cover every route, in the nav's order" do
      assert AdminNav.keys() == Enum.map(@routes, &elem(&1, 1))
      for {_, key, label, _} <- @routes, do: assert(AdminNav.label(key) == label)
    end

    test "content width: narrow for the Configuration forms, wide for the rest" do
      for {_, key, _, width} <- @routes, do: assert(AdminNav.content_width(key) == width)
    end

    test "Sign-ups is listed by approval, or while it is the current section" do
      keys = fn current, mode -> Enum.map(AdminNav.sections(current, mode), &elem(&1, 0)) end

      assert :signups in keys.(:people, :approval)
      refute :signups in keys.(:people, :closed)
      refute :signups in keys.(:server, :open)
      assert :signups in keys.(:signups, :closed)
      assert length(keys.(:people, :closed)) == length(@routes) - 1
    end
  end
end
