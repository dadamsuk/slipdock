defmodule SlipdockWeb.HelpLiveTest do
  @moduledoc """
  Help: a hub at /help, a guide per part of the app at /help/:section, and
  connecting an agent at /help/agents and /help/agents/:topic. What matters:
  every page opens signed out as well as in, the hub reaches every section
  and every part of one, the agent pages carry this server's own address, the
  agent topics' first addresses (/help/mcp) still land, and a name that isn't
  a page goes somewhere sensible rather than crashing.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.HelpLive.{Agents, Guides}

  @sections ~w(boards wiki sharing automations tools ai)
  @topics ~w(guide mcp cli skills runners webhooks)

  defp doc(html), do: LazyHTML.from_document(html)
  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  describe "the hub" do
    @tag :anonymous
    test "opens signed out, with a way to sign in", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/help")

      assert html =~ "kanban board with a wiki"
      assert has_element?(view, ~s{a[href="/login"]}, "Sign in")
    end

    test "opens signed in, without offering to sign in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")

      assert has_element?(view, "#help-sections")
      refute has_element?(view, ~s{a[href="/login"]})
    end

    @tag :anonymous
    test "has a card for every section and Agents, linking to each part", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")

      for section <- Guides.sections() do
        assert has_element?(view, ~s{#help-hub-#{section.slug} a[href="/help/#{section.slug}"]})

        for {id, _title} <- section.parts do
          assert has_element?(
                   view,
                   ~s{#help-hub-#{section.slug} a[href="/help/#{section.slug}##{id}"]}
                 )
        end
      end

      assert has_element?(view, ~s{#help-hub-agents a[href="/help/agents"]})

      assert has_element?(
               view,
               ~s{#help-hub-agents-summary[href="/help/agents"]},
               "Summary: every way in, side by side"
             )

      for slug <- @topics,
          do: assert(has_element?(view, ~s{#help-hub-agents a[href="/help/agents/#{slug}"]}))
    end

    @tag :anonymous
    test "following a section's link patches to it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")

      view |> element(~s{#help-hub-wiki h2 a}) |> render_click()

      assert_patch(view, ~p"/help/wiki")
      assert has_element?(view, "#help-section-wiki")
      refute has_element?(view, "#help-sections")
    end
  end

  describe "a section" do
    @tag :anonymous
    test "every section opens, marked current in the nav", %{conn: conn} do
      for slug <- @sections do
        {:ok, view, _html} = live(conn, ~p"/help/#{slug}")

        assert has_element?(view, "#help-section-#{slug}")

        assert has_element?(
                 view,
                 ~s{#help-sections-nav a[aria-current="page"][href="/help/#{slug}"]}
               )

        assert has_element?(view, ~s{#help-sections-nav a[href="/help"]})
      end
    end

    @tag :anonymous
    test "every part the hub links to is on its page, once", %{conn: conn} do
      for section <- Guides.sections() do
        {:ok, view, html} = live(conn, ~p"/help/#{section.slug}")

        for {id, title} <- section.parts do
          assert count(doc(html), "##{id}") == 1, "#{section.slug} has no part ##{id}"
          assert has_element?(view, "##{id} h2", title)
          assert has_element?(view, ~s{#help-section-#{section.slug} header a[href="##{id}"]})
        end
      end
    end

    @tag :anonymous
    test "the AI section covers the three ways to ask", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/ai")

      assert has_element?(view, "#ai-board h2", "Ask about this board")
      assert has_element?(view, "#ai-search h2", "Search anywhere")
      assert has_element?(view, "#ai-ask h2", "Ask about anywhere")
      assert has_element?(view, "#ai-which table tbody tr", "Ask about anywhere")
    end

    @tag :anonymous
    test "signed out, places in the app are named but not linked", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/help/ai")

      assert html =~ "Account → Settings → AI model"
      refute has_element?(view, ~s{a[href="/account/settings"]})
      refute has_element?(view, ~s{a[href="/search"]})
      refute has_element?(view, ~s{a[href="/ask"]})
    end

    test "signed in, places in the app are links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/ai")

      assert has_element?(view, ~s{#ai-model a[href="/account/settings"]})
      assert has_element?(view, ~s{#ai-search a[href="/search"]}, "Search")
      assert has_element?(view, ~s{#ai-ask a[href="/ask"]}, "Ask")
    end

    @tag :anonymous
    test "an unknown section goes back to the hub with a message", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/help"}}} = result = live(conn, ~p"/help/nope")
      {:ok, view, html} = follow_redirect(result, conn)

      assert html =~ "There is no help page by that name."
      assert has_element?(view, "#help-sections")
    end

    test "the sections and parts have unique slugs and ids" do
      slugs = Guides.slugs()
      ids = for s <- Guides.sections(), {id, _} <- s.parts, do: id

      assert slugs == @sections
      assert Enum.uniq(ids) == ids
      # A section must never shadow /help/agents, nor an old agent address.
      assert Enum.empty?(slugs -- (slugs -- ["agents" | Agents.slugs()]))
    end
  end

  describe "agents" do
    @tag :anonymous
    test "the overview opens signed out, under the Agents tab", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/help/agents")

      assert html =~ "Working with an AI agent"

      assert has_element?(
               view,
               ~s{#help-sections-nav a[aria-current="page"][href="/help/agents"]}
             )

      # Nothing that only works signed in is offered as a link.
      refute has_element?(view, ~s{a[href="/account/agent"]})
    end

    test "signed in, the overview offers setup", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents")
      assert has_element?(view, ~s{a[href="/account/agent"]})
    end

    @tag :anonymous
    test "introduces each way in and links to its page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents")

      for slug <- @topics do
        assert has_element?(view, ~s{#help-way-#{slug} a[href="/help/agents/#{slug}"]})
        assert has_element?(view, ~s{#help-compare-table thead a[href="/help/agents/#{slug}"]})
      end
    end

    @tag :anonymous
    test "the table has a cell for every way in on every row", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents")
      rows = LazyHTML.query(doc(html), "#help-compare-table tbody tr")

      assert Enum.count(rows) > 5

      for row <- rows, do: assert(count(row, "td") == length(@topics))
    end

    @tag :anonymous
    test "the table says MCP attaches files and manages automations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents")
      mcp = Enum.find_index(@topics, &(&1 == "mcp"))

      for label <- ["Attach and download files", "List and change a board's automations"] do
        row =
          doc(html)
          |> LazyHTML.query("#help-compare-table tbody tr")
          |> Enum.find(&(LazyHTML.text(LazyHTML.query(&1, "th")) =~ label))

        assert row, "no row #{label}"
        cell = row |> LazyHTML.query("td") |> Enum.at(mcp)
        assert LazyHTML.attribute(LazyHTML.query(cell, "[data-mark]"), "data-mark") == ["yes"]
      end
    end

    @tag :anonymous
    test "the table's marks are said in words for screen readers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents")

      assert has_element?(view, ~s{#help-compare-table [data-mark="yes"] .sr-only}, "Yes")
      assert has_element?(view, ~s{#help-compare-table [data-mark="some"] .sr-only}, "Partly")
      assert has_element?(view, ~s{#help-compare-table [data-mark="no"] .sr-only}, "No")
    end

    @tag :anonymous
    test "every topic page opens, marked current", %{conn: conn} do
      for slug <- @topics do
        {:ok, view, _html} = live(conn, ~p"/help/agents/#{slug}")

        assert has_element?(view, "#help-topic-#{slug}")

        assert has_element?(
                 view,
                 ~s{#help-topics a[aria-current="page"][href="/help/agents/#{slug}"]}
               )

        assert has_element?(view, ~s{#help-topics a[href="/help/agents"]})
      end
    end

    @tag :anonymous
    test "a way in's link patches to its page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents")

      view |> element("#help-way-mcp a", "More about MCP") |> render_click()

      assert_patch(view, ~p"/help/agents/mcp")
      assert has_element?(view, "#help-topic-mcp")
      refute has_element?(view, "#help-compare")
    end

    @tag :anonymous
    test "the first addresses of the topics still land on them", %{conn: conn} do
      for slug <- @topics do
        assert {:error, {:live_redirect, %{to: to}}} = result = live(conn, ~p"/help/#{slug}")
        assert to == ~p"/help/agents/#{slug}"

        {:ok, view, _html} = follow_redirect(result, conn)
        assert has_element?(view, "#help-topic-#{slug}")
      end
    end

    @tag :anonymous
    test "an unknown topic goes back to the agents overview with a message", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/help/agents"}}} =
               result = live(conn, ~p"/help/agents/nope")

      {:ok, view, html} = follow_redirect(result, conn)

      assert html =~ "There is no help page by that name."
      assert has_element?(view, "#help-compare")
    end

    @tag :anonymous
    test "the pages carry the address they were reached on", %{conn: conn} do
      # The test request's host, not the endpoint's configured localhost:4000:
      # what's copied from here has to work against the server that drew it.
      base = "http://www.example.com"

      {:ok, view, _html} = live(conn, ~p"/help/agents/mcp")
      assert has_element?(view, "#help-mcp-url", "#{base}/mcp")

      {:ok, view, _html} = live(conn, ~p"/help/agents/guide")
      assert has_element?(view, "#help-guide-prompt", "#{base}/api/guide")

      {:ok, view, _html} = live(conn, ~p"/help/agents/skills")
      assert has_element?(view, "#help-skills-sh", "#{base}/install.sh")
    end

    @tag :anonymous
    test "account pages are named but not linked signed out", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/help/agents/guide")

      assert html =~ "Account → API tokens"
      refute has_element?(view, ~s{a[href="/account/tokens"]})
    end

    test "account pages are links signed in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents/guide")
      assert has_element?(view, ~s{a[href="/account/tokens"]})
    end

    @tag :anonymous
    test "the skills page offers each ChatGPT zip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents/skills")

      skills = Slipdock.Skills.ChatGPT.list()
      assert skills != []

      for skill <- skills do
        assert has_element?(view, ~s{a[href="/api/skills/#{skill.name}/chatgpt.zip"]})
      end

      refute has_element?(view, ~s{a[href="/api/skills/slipdock-loop/chatgpt.zip"]})
    end

    test "topics are listed in the order the page presents them" do
      assert Agents.slugs() == @topics
    end
  end

  @tag :anonymous
  test "every snippet on every page has a copy button pointing at it", %{conn: conn} do
    paths = Enum.map(@sections, &"/help/#{&1}") ++ Enum.map(@topics, &"/help/agents/#{&1}")

    for path <- paths do
      {:ok, _view, html} = live(conn, path)
      page = doc(html)

      for button <- LazyHTML.query(page, "button[phx-hook=CopyText]") do
        [target] = LazyHTML.attribute(button, "data-target")
        assert count(page, "code##{target}") == 1, "#{path}: no code##{target}"
      end
    end
  end

  @tag :anonymous
  test "every link in the content is styled as a link", %{conn: conn} do
    paths =
      ["/help", "/help/agents"] ++
        Enum.map(@sections, &"/help/#{&1}") ++ Enum.map(@topics, &"/help/agents/#{&1}")

    for path <- paths do
      {:ok, _view, html} = live(conn, path)

      # The tab rows are tabs, and look like them; everything else is prose.
      links =
        doc(html)
        |> LazyHTML.query("#help a:not(#help-sections-nav a):not(#help-topics a)")

      assert Enum.count(links) > 0

      for link <- links do
        [href] = LazyHTML.attribute(link, "href")
        classes = link |> LazyHTML.attribute("class") |> Enum.join(" ") |> String.split()
        assert "link" in classes, "#{path}: #{href} doesn't look like a link"
        refute "link-hover" in classes, "#{path}: #{href} is only underlined on hover"
      end
    end
  end

  describe "the ways to Help" do
    @tag :anonymous
    test "the sign-in page links to help and to agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/login")

      assert has_element?(view, ~s{#login-help[href="/help"]})
      assert has_element?(view, ~s{#login-help-agents[href="/help/agents"]})
    end

    test "the avatar menu links to help, the agent tab to agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/agent")

      assert has_element?(view, ~s{a[href="/help"]}, "Help")
      assert has_element?(view, ~s{a[href="/help/agents"]}, "Compare them in Help")
    end
  end

  describe "Tools (#967)" do
    test "the guide covers installing, safety, upgrades, publishing and the package", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/help/tools")

      assert has_element?(view, "#tools-install", "Make the board")
      assert has_element?(view, "#tools-safety", "every skill file in full")
      assert has_element?(view, "#tools-upgrade", "never overwritten")
      assert has_element?(view, "#tools-publish", "slipdock tools publish")
      assert has_element?(view, "#tools-format", "board.json")
      assert has_element?(view, "#tools-listing", "admin")
    end

    test "the agents pages name install_tool, list_tools and the package", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/help/agents/skills")
      assert has_element?(view, "#help-skills-tools", "install_tool")
      assert has_element?(view, "#help-skills-tools", "list_tools")
      assert has_element?(view, "#help-skills-tools", "tool.json")

      {:ok, _view, html} = live(conn, ~p"/help/agents/mcp")
      assert html =~ "install_tool"
    end

    test "the MCP page names the prompts; capture-this-chat only while chat capture is on",
         %{conn: conn} do
      # Without a finished setup, a settings row sends every page to /setup.
      {:ok, _} = Slipdock.Settings.complete_setup(%{"admin_email" => "admin@example.com"})
      {:ok, view, _} = live(conn, ~p"/help/agents/mcp")
      assert has_element?(view, "#help-mcp-prompts", "plan-my-day")
      assert has_element?(view, "#help-mcp-prompts", "tidy-board")
      assert has_element?(view, "#help-mcp-prompts", "capture-this-chat")

      {:ok, _} = Slipdock.Settings.update(%{"chat_capture_enabled" => false})
      {:ok, view, _} = live(conn, ~p"/help/agents/mcp")
      assert has_element?(view, "#help-mcp-prompts", "resume")
      refute has_element?(view, "#help-mcp-prompts", "capture-this-chat")
    end
  end
end
