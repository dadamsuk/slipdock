defmodule SlipdockWeb.PageFrameLiveTest do
  @moduledoc """
  Every page on the list in #1714 frames itself the same way: one `h1`,
  drawn by `page_header/1` inside a `page/1` frame at one of the three
  widths (narrow for forms and settings, standard for lists, full for
  boards, tables and dashboards). The layout's header row doesn't repeat
  the title. The home page's title is "Boards", not the wordmark.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  @widths ~w(narrow standard full)

  # {path, the h1's text, the width}. A board's pages take the board's id.
  @pages [
    {"/", "Boards", "full"},
    {"/work", "My work", "standard"},
    {"/wiki/.settings", "Wiki settings", "narrow"},
    {"/favourites", "Favourites", "standard"},
    {"/shared", "Shared with me", "standard"},
    {"/multiboard", "Multiboard", "full"},
    {"/templates", "Templates", "standard"},
    {"/tools", "Tools", "standard"},
    {"/groups", "Groups", "standard"},
    {"/search", "Search", "standard"},
    {"/ask", "Ask", "standard"},
    {"/boards/:id/tidy", "Tidy up", "standard"},
    {"/boards/:id/visualise", "Visualise", "full"},
    {"/help", "Help", "standard"},
    # The settings layout (#1737): a side nav beside a narrow content column.
    {"/account", "Account", "standard"},
    {"/account/settings", "Account", "standard"},
    {"/account/sign-in", "Account", "standard"},
    {"/account/tokens", "Account", "standard"},
    {"/account/agent", "Account", "standard"},
    {"/account/data", "Account", "standard"}
  ]

  @admin_pages [
    {"/users", "Users", "full"},
    {"/overview", "Overview", "full"},
    # The rest of the app's own pages (#1712): Configuration and its tabs,
    # and the queue of tool listings.
    {"/config", "Configuration", "narrow"},
    {"/config/mail", "Configuration", "narrow"},
    {"/config/ai", "Configuration", "narrow"},
    {"/admin/tools", "Tool listings", "standard"}
  ]

  defp check(view, html, path, title, width) do
    h1s = html |> LazyHTML.from_fragment() |> LazyHTML.query("h1")
    assert Enum.count(h1s) == 1, "#{path} has #{Enum.count(h1s)} h1s"

    assert LazyHTML.text(h1s) |> String.split() |> Enum.join(" ") == title,
           "#{path}'s h1 is #{inspect(LazyHTML.text(h1s))}, not #{inspect(title)}"

    assert width in @widths

    assert has_element?(view, ~s([data-page-width="#{width}"] header[data-role=page-header] h1)),
           "#{path} isn't a #{width} page with its h1 in a page_header"

    # One frame per page, so its width is the page's.
    frames = html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-page-width]")
    assert Enum.count(frames) == 1, "#{path} has #{Enum.count(frames)} page frames"
  end

  defp at(path, board), do: String.replace(path, ":id", to_string(board.id))

  describe "a signed-in person" do
    setup %{user: user} do
      %{board: board_fixture(%{"name" => "Framed"}, owner: user)}
    end

    for {path, title, width} <- @pages do
      test "#{path} has one h1, #{inspect(title)}, at the #{width} width", %{
        conn: conn,
        board: board
      } do
        path = at(unquote(path), board)
        {:ok, view, _} = live(conn, path)
        check(view, render(view), path, unquote(title), unquote(width))
      end
    end

    test "the home page's h1 is the word Boards, not the wordmark", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "h1", "Boards")
      refute has_element?(view, "h1 img")
      refute has_element?(view, "h1 [alt=Slipdock]")
      # The counts are its subtitle.
      assert has_element?(view, "h1 + [data-role=page-subtitle] #board-count", "1 board")
    end

    test "Templates is called Templates on the page, as everywhere else", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/templates")

      assert has_element?(view, "h1", "Templates")
      refute html =~ "Board templates"
      assert has_element?(view, "[data-role=page-actions] #new-template", "New template")
    end

    test "Account's first section is Profile, so Account is said once", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/account")

      assert has_element?(view, "h1", "Account")
      assert has_element?(view, "#account-nav a[href='/account']", "Profile")
      refute has_element?(view, "#account-nav a", "Account")
      assert has_element?(view, "#account-content [data-role=settings-section-title]", "Profile")
    end

    test "a saved multiboard is titled with its name and keeps the title's id", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/multiboard")
      assert has_element?(view, "h1#multiboard-title", "Multiboard")
      assert has_element?(view, "[data-role=page-subtitle] #multiboard-summary")
    end

    test "a help section and an agent topic each have one h1", %{conn: conn} do
      for path <- [~p"/help/agents"] do
        {:ok, _view, html} = live(conn, path)
        h1s = html |> LazyHTML.from_fragment() |> LazyHTML.query("h1")
        assert Enum.count(h1s) == 1, "#{path} has #{Enum.count(h1s)} h1s"
      end
    end

    test "Tidy up's header row names the board, not the page again", %{
      conn: conn,
      board: board
    } do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/tidy")
      [_, page] = String.split(html, ~s(data-page-width=), parts: 2)
      [above, _] = String.split(html, ~s(data-page-width=), parts: 2)

      assert page =~ "Tidy up"
      refute above =~ ~r/>\s*Tidy up\s*</
      assert above =~ "Framed"
    end

    test "an ordinary person can't reach the admin pages", %{conn: conn} do
      for {path, _, _} <- @admin_pages do
        assert {:error, {:redirect, _}} = live(conn, path)
      end
    end
  end

  describe "a tool's own page (#1712)" do
    setup %{user: user} do
      Slipdock.TestConfig.own_uploads_dir()
      name = Slipdock.ToolPackages.unique_name()
      {:ok, v1} = Slipdock.Tools.publish(user, Slipdock.ToolPackages.package(name))
      %{tool: v1.tool, name: name}
    end

    test "has one h1, the tool's name, at the standard width", %{conn: conn, tool: tool} do
      {:ok, view, html} = live(conn, ~p"/tools/#{tool.slug}")
      doc = view |> render() |> LazyHTML.from_fragment()

      # The page's own title is the one h1 outside the README, which is the
      # tool's document and keeps its own headings.
      outside = LazyHTML.query(doc, "h1:not(.prose h1)")
      assert Enum.count(outside) == 1
      assert LazyHTML.text(outside) |> String.trim() == tool.name
      assert has_element?(view, ~s([data-page-width="standard"] #tool-page-header h1), tool.name)
      assert doc |> LazyHTML.query("[data-page-width]") |> Enum.count() == 1

      # The header row goes back to Tools; it doesn't repeat the name.
      [above, _] = String.split(html, ~s(data-page-width=), parts: 2)
      assert above =~ ~s(href="/tools")
      refute above =~ ~r/>\s*#{Regex.escape(tool.name)}\s*</
      refute has_element?(view, "#tool-versions")
    end

    test "with two versions, the picker is the header's action", %{
      conn: conn,
      user: user,
      tool: tool,
      name: name
    } do
      {:ok, _} = Slipdock.Tools.publish(user, Slipdock.ToolPackages.package(name, "1.1.0"))
      {:ok, view, _} = live(conn, ~p"/tools/#{tool.slug}")

      assert has_element?(
               view,
               "#tool-page-header [data-role=page-actions] #tool-versions",
               "1.1.0"
             )

      assert has_element?(view, "#tool-header", "version 1.1.0")
    end
  end

  describe "an admin" do
    setup %{conn: conn} do
      {:ok, _} =
        Settings.complete_setup(%{
          "admin_email" => fixture_email("admin@example.com"),
          "signup_mode" => :closed
        })

      {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
      %{conn: log_in_user(conn, admin)}
    end

    for {path, title, width} <- @admin_pages do
      test "#{path} has one h1, #{inspect(title)}, at the #{width} width", %{conn: conn} do
        {:ok, view, _} = live(conn, unquote(path))
        check(view, render(view), unquote(path), unquote(title), unquote(width))
      end
    end
  end
end
