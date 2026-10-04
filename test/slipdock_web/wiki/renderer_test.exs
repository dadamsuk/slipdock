defmodule SlipdockWeb.Wiki.RendererTest do
  @moduledoc """
  What a page draws: every kind of reference, the directives, each shape of
  query answer — as HTML for a screen and as Markdown for an agent — and the
  published-page modes where nobody is reading with permissions.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Wiki}
  alias SlipdockWeb.Wiki.Renderer

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    [backlog, doing | _] = board.columns

    open = card_fixture(backlog, %{"title" => "Open | piped", "priority" => "high"})
    done = card_fixture(doing, %{"title" => "Shipped", "completed" => true})

    %{user: user, board: Boards.get_board!(board.id), cards: %{open: open, done: done}}
  end

  describe "input it cannot use" do
    test "a body that is not a string renders as nothing" do
      assert Renderer.to_html(nil) == ""
      assert Renderer.to_markdown(nil) == ""
      assert Renderer.excerpt(nil) == ""
    end

    test "references with no board to read them against stay as written" do
      html = Renderer.to_html("See [[Retry policy]] and #12 and @tester")
      assert html =~ "[[Retry policy]]"
      assert html =~ "#12"
      refute html =~ "<a "

      assert Renderer.to_markdown("See [[Retry policy|the policy]] and [[Other]]") ==
               "See the policy and Other"
    end
  end

  describe "references" do
    test "a board, a saved view and a mention", %{board: board, user: user} do
      {:ok, view} = Boards.create_saved_view(board, %{"name" => "Blocked work", "config" => %{}})

      body = "[[board:handbook]], [[view:Blocked work|the blocked list]] and @tester."
      html = Renderer.to_html(body, board: board, as: user)

      assert html =~
               ~s|<a href="/boards/#{board.id}" class="wiki-link wiki-link-board" rel="noopener noreferrer">Handbook</a>|

      assert html =~
               ~s|<a href="/boards/#{board.id}?view=#{view.id}" class="wiki-link wiki-link-view" rel="noopener noreferrer">the blocked list</a>|

      assert html =~ ~s|class="wiki-mention" title="tester@example.com"|
      assert html =~ "@#{Wiki.author_name(user)}"

      markdown = Renderer.to_markdown(body, board: board, as: user)
      assert markdown =~ "[Handbook](/boards/#{board.id})"
      assert markdown =~ "[the blocked list](/boards/#{board.id}?view=#{view.id})"
      assert markdown =~ "@#{Wiki.author_name(user)}"
    end

    test "a finished card's chip says so, with its list", %{
      board: board,
      user: user,
      cards: cards
    } do
      html = Renderer.to_html("##{cards.done.id}", board: board, as: user)

      assert html =~ ~s|class="wiki-chip wiki-chip-done"|

      assert html =~ ~s|<span class="wiki-chip-meta">In Progress · done</span>| or
               html =~
                 ~s|<span class="wiki-chip-meta">#{Enum.at(board.columns, 1).name} · done</span>|

      assert Renderer.to_markdown("##{cards.done.id}", board: board, as: user) ==
               "Shipped (##{cards.done.id}, #{Enum.at(board.columns, 1).name}, done)"
    end

    test "escapes what people wrote in titles and labels", %{board: board, user: user} do
      [backlog | _] = board.columns
      card = card_fixture(backlog, %{"title" => "<b>bold</b> & co"})

      html = Renderer.to_html("##{card.id}", board: board, as: user)
      assert html =~ "&lt;b&gt;bold&lt;/b&gt; &amp; co"
      refute html =~ "<b>bold</b>"
    end

    test "on a published page references are named, not linked", %{
      board: board,
      user: user,
      cards: cards
    } do
      {:ok, _} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      html =
        Renderer.to_html(
          "[[Retry policy|the policy]], ##{cards.open.id} and [[Not written|a gap]]",
          board: board,
          static: true
        )

      assert html =~ ~s|<span class="wiki-static">the policy</span>|
      assert html =~ ~s|<span class="wiki-static">##{cards.open.id}</span>|
      # A wanted page on a published page is not an invitation to anybody.
      assert html =~ "a gap"
      refute html =~ "wiki-wanted"
      refute html =~ "<a "
    end
  end

  describe "directives" do
    test "toc, children and backlinks when there is nothing to list", %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Lonely", "body" => "Text."}, user: user)

      assert Renderer.to_html("[[!toc]]", page: page, board: board, as: user) == ""

      assert Renderer.to_html("[[!children]]", page: page, as: user) =~
               "No pages under this one yet."

      assert Renderer.to_html("[[!backlinks]]", page: page, board: board, as: user) =~
               "Nothing links here yet."

      # Without a page to be about, a directive draws nothing.
      assert Renderer.to_html("[[!toc]]", board: board) == ""
      assert Renderer.to_markdown("[[!children]]", board: board) == ""
    end

    test "children carry their summaries, backlinks name who links here", %{
      board: board,
      user: user
    } do
      {:ok, parent} =
        Wiki.create_page(board, %{"title" => "Deploys", "body" => "# One\n\n## Two & three"},
          user: user
        )

      {:ok, _} =
        Wiki.create_page(
          board,
          %{"title" => "Rollback", "parent_id" => parent.id, "summary" => "Undo <it>"},
          user: user
        )

      {:ok, _} =
        Wiki.create_page(board, %{"title" => "Runbook", "body" => "See [[Deploys]]."}, user: user)

      parent = Wiki.get_page!(parent.id)

      children = Renderer.to_html("[[!children]]", page: parent, as: user)
      assert children =~ ~s|<span class="wiki-list-summary">Undo &lt;it&gt;</span>|

      backlinks = Renderer.to_html("[[!backlinks]]", page: parent, as: user)
      assert backlinks =~ ~s|class="wiki-backlinks"|
      assert backlinks =~ ">Runbook</a>"

      toc = Renderer.to_html("[[!toc]]", page: parent, as: user)

      assert toc =~
               ~s|<li class="wiki-toc-2"><a href="#two--three" rel="noopener noreferrer">Two &amp; three</a></li>|

      assert Renderer.to_markdown("[[!toc]]", page: parent, as: user) == "- One\n  - Two & three"

      assert Renderer.to_markdown("[[!children]]", page: parent, as: user) =~
               ~r|^- \[Rollback\]\(/boards/#{board.id}/wiki/rollback\) — Undo <it>$|

      assert Renderer.to_markdown("[[!backlinks]]", page: parent, as: user) ==
               "- [Runbook](/boards/#{board.id}/wiki/runbook)"
    end
  end

  describe "query answers as HTML" do
    defp block(source), do: "```slipdock\n#{source}\n```"

    test "a count is one card or several", %{board: board, user: user} do
      opts = [board: board, as: user]

      assert Renderer.to_html(block("view: count\nfilter: priority=high"), opts) =~
               ~s|<span class="wiki-query-number">1</span> card</p>|

      assert Renderer.to_html(block("view: count"), opts) =~
               ~s|<span class="wiki-query-number">2</span> cards</p>|
    end

    test "progress for one card's tree carries its title", %{
      board: board,
      user: user,
      cards: cards
    } do
      html =
        Renderer.to_html(block("view: progress\ncard: #{cards.done.id}"), board: board, as: user)

      assert html =~ ~s|<span class="wiki-progress-label">Shipped</span>|
      assert html =~ "1 of 1 done (100%)"

      plain = Renderer.to_html(block("view: progress"), board: board, as: user)
      refute plain =~ "wiki-progress-label"
      assert plain =~ "1 of 2 done (50%)"
    end

    test "a table links each title, and an empty one says so", %{
      board: board,
      user: user,
      cards: cards
    } do
      html =
        Renderer.to_html(block("view: table\nfields: title, priority\nsort: title asc"),
          board: board,
          as: user
        )

      assert html =~ "<th>Title</th><th>Priority</th>"

      assert html =~
               ~s|<td><a href="/boards/#{board.id}/cards/#{cards.done.id}" class="wiki-query-card wiki-chip-done" rel="noopener noreferrer">Shipped</a></td>|

      assert html =~ "<td>high</td>"

      assert Renderer.to_html(block("filter: priority=critical"), board: board, as: user) =~
               ~s|<p class="wiki-empty">No cards match.</p>|

      assert Renderer.to_html(block("view: list\nfilter: priority=critical\nempty: All clear"),
               board: board,
               as: user
             ) =~ ~s|<p class="wiki-empty">All clear</p>|
    end

    test "groups are headed with their size", %{board: board, user: user} do
      html = Renderer.to_html(block("view: board"), board: board, as: user)
      [backlog, doing | _] = board.columns

      assert html =~
               ~s|<p class="wiki-query-group">#{backlog.name} <span class="wiki-query-group-count">1</span></p>|

      assert html =~ doing.name

      assert Renderer.to_html(block("view: board\nfilter: priority=critical"),
               board: board,
               as: user
             ) =~
               "No cards match."
    end

    test "on a published page a card is named rather than linked", %{board: board, user: user} do
      html = Renderer.to_html(block("view: list"), board: board, as: user, static: true)
      assert html =~ "<li>Shipped</li>"
      refute html =~ "wiki-query-card"
    end

    test "a published page answers from what was frozen, and says when it was not", %{
      board: board
    } do
      frozen = %{
        "view: count" => %{"kind" => "count", "count" => 7},
        "count: flag=blocked" => "3"
      }

      html = Renderer.to_html(block("view: count"), board: board, static: true, frozen: frozen)
      assert html =~ ~s|<span class="wiki-query-number">7</span> cards|

      missing = Renderer.to_html(block("view: list"), board: board, static: true, frozen: frozen)
      assert missing =~ "this query was not answered when the page was published"

      inline =
        Renderer.to_html("{{count: flag=blocked}} and {{today}}", board: board, frozen: frozen)

      assert inline =~ ~s|<span class="wiki-inline">3</span>|
      # Not frozen, so left exactly as written.
      assert inline =~ "{{today}}"
    end
  end

  describe "query answers as Markdown" do
    defp md(source, context), do: Renderer.to_markdown("```slipdock\n#{source}\n```", context)

    test "each shape of answer", %{board: board, user: user, cards: cards} do
      opts = [board: board, as: user]

      assert md("view: count", opts) == "2"
      assert md("view: progress", opts) == "1 of 2 done (50%)"

      assert md("view: progress\ncard: #{cards.done.id}", opts) ==
               "1 of 1 done (100%) — Shipped"

      assert md("view: table\nfields: title, priority\nsort: title asc", opts) ==
               "| Title | Priority |\n|---|---|\n| Open \\| piped | high |\n| Shipped |  |"

      [backlog, doing | _] = board.columns

      assert md("view: board", opts) ==
               "**#{backlog.name}**\n- Open | piped (##{cards.open.id})\n\n" <>
                 "**#{doing.name}**\n- Shipped (##{cards.done.id})"

      assert md("view: list\nfilter: priority=critical", opts) == "_No cards match._"
      assert md("filter: priority=critical", opts) == "_No cards match._"
      assert md("view: board\nfilter: priority=critical\nempty: Quiet.", opts) == "Quiet."
    end

    test "a query that cannot be answered is quoted with its source", %{board: board, user: user} do
      assert md("filter: nonsense", board: board, as: user) =~
               ~r/^> \*\*This query could not be answered:\*\* there is nothing called/

      assert md("filter: nonsense", board: board, as: user) =~ "> filter: nonsense"
    end

    # The canonical fence is ```slipdock; `render` only knew the pre-rename
    # ```kanban spelling, so an agent got the query back instead of the answer.
    test "every spelling of the fence is answered, as on screen", %{board: board, user: user} do
      for fence <- ~w(slipdock slipdock-query kanban kanban-query) do
        assert Renderer.to_markdown("```#{fence}\nview: count\n```", board: board, as: user) ==
                 "2",
               "```#{fence} was not answered"
      end

      # Other code blocks are left alone.
      assert Renderer.to_markdown("```elixir\nview: count\n```", board: board) ==
               "```elixir\nview: count\n```"
    end

    test "a block left open at the end of the page is still answered", %{board: board, user: user} do
      assert Renderer.to_markdown("Total:\n~~~slipdock\nview: count", board: board, as: user) ==
               "Total:\n2"
    end
  end

  describe "excerpt and anchors" do
    test "the first paragraph of prose, as plain text" do
      body = """
      # Heading

      [[!toc]]

      ```
      code
      ```

      A *first* paragraph with [a link](https://example.com) and `code`
      over two lines.

      A second one.
      """

      assert Renderer.excerpt(body) == "A first paragraph with a link and code over two lines."
      assert Renderer.excerpt(body, 12) == "A first par…"
      assert Renderer.excerpt("# Only a heading") == ""
    end

    test "anchor matches the ids comrak gives headings" do
      # A table of contents and a search hit both link to these, so a
      # mismatch is a link that goes nowhere. It used to collapse runs of
      # spaces and drop underscores, which comrak does neither of.
      for title <- ["Two & Three", "  Ünïcode heading!  ", "a_b c.d", "x - y", "Plain"] do
        html = Renderer.to_html("## " <> title)
        assert html =~ ~s|<h2 id="#{Renderer.anchor(title)}">|, "anchor for #{inspect(title)}"
      end

      assert Renderer.anchor("Two & Three") == "two--three"
      assert Renderer.anchor("a_b c.d") == "a_b-cd"
    end
  end
end
