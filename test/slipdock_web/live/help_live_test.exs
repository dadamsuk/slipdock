defmodule SlipdockWeb.HelpLiveTest do
  @moduledoc """
  The Help pages about connecting an agent. What matters: they open signed
  out as well as in, the overview introduces and compares every way in and
  links to each one's page, those pages carry this server's own address, and
  a name that isn't a topic goes back to the overview rather than crashing.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.HelpLive.Index

  @slugs ~w(guide mcp cli skills runners webhooks)

  describe "signed out" do
    @tag :anonymous
    test "the overview opens, with a way to sign in", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/help")

      assert html =~ "Working with an AI agent"
      assert has_element?(view, ~s{a[href="/login"]}, "Sign in")
      # Nothing that only works signed in is offered as a link.
      refute has_element?(view, ~s{a[href="/account/agent"]})
    end

    @tag :anonymous
    test "every topic page opens", %{conn: conn} do
      for slug <- @slugs do
        {:ok, view, _html} = live(conn, ~p"/help/#{slug}")
        assert has_element?(view, "#help-topic-#{slug}")
        assert has_element?(view, ~s{#help-topics a[aria-current="page"]})
      end
    end

    @tag :anonymous
    test "account pages are named but not linked", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/help/guide")

      assert html =~ "Account → API tokens"
      refute has_element?(view, ~s{a[href="/account/tokens"]})
    end

    @tag :anonymous
    test "the sign-in page links to help", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/login")
      assert has_element?(view, ~s{#login-help[href="/help"]})
    end
  end

  describe "signed in" do
    test "the overview opens, offering setup instead of sign in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")

      assert has_element?(view, ~s{a[href="/account/agent"]})
      refute has_element?(view, ~s{a[href="/login"]})
    end

    test "account pages are links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/guide")
      assert has_element?(view, ~s{a[href="/account/tokens"]})
    end

    test "the avatar menu and the agent tab link to help", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/agent")
      assert has_element?(view, ~s{a[href="/help"]}, "Help with agents")
      assert has_element?(view, ~s{a[href="/help"]}, "Compare them in Help")
    end
  end

  describe "the overview" do
    @tag :anonymous
    test "introduces each way in and links to its page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")

      for slug <- @slugs do
        assert has_element?(view, "#help-way-#{slug}")
        assert has_element?(view, ~s{#help-way-#{slug} a[href="/help/#{slug}"]})
        assert has_element?(view, ~s{#help-compare-table thead a[href="/help/#{slug}"]})
      end
    end

    @tag :anonymous
    test "the table has a cell for every way in on every row", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help")
      rows = html |> LazyHTML.from_document() |> LazyHTML.query("#help-compare-table tbody tr")

      assert Enum.count(rows) > 5

      for row <- rows do
        assert row |> LazyHTML.query("td") |> Enum.count() == length(@slugs)
      end
    end

    @tag :anonymous
    test "the table's marks are said in words for screen readers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")

      assert has_element?(view, ~s{#help-compare-table [data-mark="yes"] .sr-only}, "Yes")
      assert has_element?(view, ~s{#help-compare-table [data-mark="some"] .sr-only}, "Partly")
      assert has_element?(view, ~s{#help-compare-table [data-mark="no"] .sr-only}, "No")
    end

    @tag :anonymous
    test "following a card's link patches to its page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")

      view |> element("#help-way-mcp a", "More about MCP") |> render_click()

      assert_patch(view, ~p"/help/mcp")
      assert has_element?(view, "#help-topic-mcp")
      refute has_element?(view, "#help-compare")
    end
  end

  describe "a topic page" do
    @tag :anonymous
    test "carries the address it was reached on", %{conn: conn} do
      # The test request's host, not the endpoint's configured localhost:4000:
      # what's copied from here has to work against the server that drew it.
      base = "http://www.example.com"

      {:ok, view, _html} = live(conn, ~p"/help/mcp")
      assert has_element?(view, "#help-mcp-url", "#{base}/mcp")

      {:ok, view, _html} = live(conn, ~p"/help/guide")
      assert has_element?(view, "#help-guide-prompt", "#{base}/api/guide")

      {:ok, view, _html} = live(conn, ~p"/help/skills")
      assert has_element?(view, "#help-skills-sh", "#{base}/install.sh")
    end

    @tag :anonymous
    test "the skills page offers each ChatGPT zip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/skills")

      skills = Slipdock.Skills.ChatGPT.list()
      assert skills != []

      for skill <- skills do
        assert has_element?(view, ~s{a[href="/api/skills/#{skill.name}/chatgpt.zip"]})
      end

      refute has_element?(view, ~s{a[href="/api/skills/slipdock-loop/chatgpt.zip"]})
    end

    @tag :anonymous
    test "every snippet has a copy button pointing at it", %{conn: conn} do
      for slug <- @slugs do
        {:ok, _view, html} = live(conn, ~p"/help/#{slug}")
        doc = LazyHTML.from_document(html)

        for button <- LazyHTML.query(doc, "button[phx-hook=CopyText]") do
          [target] = LazyHTML.attribute(button, "data-target")
          assert doc |> LazyHTML.query("code##{target}") |> Enum.count() == 1
        end
      end
    end

    @tag :anonymous
    test "an unknown topic goes back to the overview with a message", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/help"}}} = result = live(conn, ~p"/help/nope")
      {:ok, view, html} = follow_redirect(result, conn)

      assert html =~ "There is no help page by that name."
      assert has_element?(view, "#help-compare")
    end
  end

  test "topics are listed in the order the page presents them" do
    assert Enum.map(Index.topics(), & &1.slug) == @slugs
  end
end
