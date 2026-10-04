defmodule Slipdock.WikiQueryTest do
  @moduledoc """
  Live query blocks: what the little language means, what it refuses, and —
  the one that matters — that a document cannot become a way to read cards
  you could not otherwise open.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Wiki.Query
  alias SlipdockWeb.Wiki.Renderer

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Queries", "code" => "queries"}, owner: user)
    [backlog, doing | _] = board.columns
    today = Date.utc_today()

    blocked =
      card_fixture(backlog, %{
        "title" => "Blocked and soon",
        "priority" => "high",
        "flags" => ["blocked"],
        "due_date" => Date.add(today, 3)
      })

    later =
      card_fixture(doing, %{
        "title" => "Later",
        "priority" => "low",
        "due_date" => Date.add(today, 60)
      })

    done = card_fixture(backlog, %{"title" => "Finished", "completed" => true})

    %{
      user: user,
      board: Boards.get_board!(board.id),
      today: today,
      cards: %{blocked: blocked, later: later, done: done}
    }
  end

  defp run(text, context) do
    with {:ok, query} <- Query.parse(text), do: Query.run(query, context)
  end

  defp titles({:ok, %{kind: :table, rows: rows}}), do: Enum.map(rows, & &1.card.title)
  defp titles({:ok, %{kind: :list, cards: cards}}), do: Enum.map(cards, & &1.title)

  defp titles({:ok, %{kind: :groups, groups: groups}}),
    do: Enum.flat_map(groups, fn g -> Enum.map(g.cards, & &1.title) end)

  describe "the filter language" do
    test "reads the operators", %{board: board, user: user} do
      context = %{board: board, reader: user}

      assert titles(run("filter: flag=blocked", context)) == ["Blocked and soon"]
      assert titles(run("filter: priority in high|critical", context)) == ["Blocked and soon"]
      assert "Later" in titles(run("filter: priority not in high", context))
      assert titles(run("filter: title ~ block", context)) == ["Blocked and soon"]
      assert titles(run("filter: due < +7d", context)) == ["Blocked and soon"]
      assert titles(run("filter: completed=true", context)) == ["Finished"]
      assert "Later" in titles(run("filter: due set", context))
      refute "Finished" in titles(run("filter: due set", context))
    end

    test "combines clauses, all of which must hold", %{board: board, user: user} do
      context = %{board: board, reader: user}

      assert titles(run("filter: due set, priority=low", context)) == ["Later"]
      assert titles(run("filter: due set, priority=critical", context)) == []
    end

    # A page placed on a board stands beside the cards in every view, so a
    # filtered query had to be able to read one — it used to raise instead.
    test "filters a wiki page placed on the board like any other card", %{
      board: board,
      user: user
    } do
      [backlog | _] = board.columns

      {:ok, page} =
        Wiki.create_page(
          board,
          %{"title" => "The spec", "summary" => "How it works", "priority" => "high"},
          user: user
        )

      {:ok, _} = Wiki.place(page, backlog)
      context = %{board: Boards.get_board!(board.id), reader: user}

      assert "The spec" in titles(run("filter: priority=high", context))
      assert "The spec" in titles(run("filter: completed=false", context))
      refute "The spec" in titles(run("filter: priority=low", context))
      # Nothing it has not got makes it match, and nothing raises.
      assert titles(run("filter: flag=blocked", context)) == ["Blocked and soon"]
      assert "The spec" in titles(run("filter: has_doc=true", context))
    end

    test "says what is wrong rather than guessing", %{board: board, user: user} do
      context = %{board: board, reader: user}

      assert {:error, message} = run("filter: nonsense here", context)
      assert message =~ "is not a filter"

      assert {:error, message} = run("filter: nonsense", context)
      assert message =~ "there is nothing called \"nonsense\" to filter on"

      assert {:error, message} = Query.parse("view: hologram")
      assert message =~ "view must be one of"

      assert {:error, message} = Query.parse("colour: red")
      assert message =~ "is not a setting here"

      assert {:error, message} = Query.parse("just some words")
      assert message =~ "should read"
    end
  end

  describe "views" do
    test "count, progress, list, table and grouping", %{board: board, user: user} do
      context = %{board: board, reader: user}

      assert {:ok, %{kind: :count, count: 1}} = run("view: count\nfilter: flag=blocked", context)

      assert {:ok, %{kind: :progress, done: 1, total: 3, percent: 33}} =
               run("view: progress", context)

      assert {:ok, %{kind: :list}} = run("view: list", context)

      assert {:ok, %{kind: :table, headers: headers, rows: [row | _]}} =
               run("view: table\nfields: title, priority, due_date\nsort: due_date asc", context)

      assert headers == ["Title", "Priority", "Due"]

      assert row.cells == [
               "Blocked and soon",
               "high",
               Date.to_iso8601(Date.add(Date.utc_today(), 3))
             ]

      assert {:ok, %{kind: :groups, groups: groups}} = run("view: board", context)
      names = Enum.map(board.columns, & &1.name)
      assert Enum.map(groups, & &1.label) == Enum.take(names, 2)
    end

    test "limit and the empty message", %{board: board, user: user} do
      context = %{board: board, reader: user}

      assert length(titles(run("limit: 1", context))) == 1

      assert {:ok, %{empty: "Nothing to see."}} =
               run("filter: priority=critical\nempty: \"Nothing to see.\"", context)
    end
  end

  describe "permissions" do
    test "a board the reader cannot read answers nothing", %{board: board} do
      outsider = user_fixture("query.outsider@example.com")

      assert {:error, message} = run("board: queries", %{board: board, reader: outsider})
      # The same answer as for a board that does not exist, so a query cannot
      # be used to find out what other people's boards are called.
      assert message =~ "there is no board called"
    end

    test "a cross-board query only reaches boards the reader can read", %{
      board: board,
      user: user
    } do
      other = board_fixture(%{"name" => "Private", "code" => "private"}, owner: user)
      card_fixture(hd(other.columns), %{"title" => "Secret"})

      reader = user_fixture("query.reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      assert titles(run("board: private", %{board: board, reader: user})) == ["Secret"]
      assert {:error, _} = run("board: private", %{board: board, reader: reader})
    end

    test "a sub-board's cards come in with `board: tree`", %{board: board, user: user} do
      card = card_fixture(hd(board.columns), %{"title" => "Epic"})
      {:ok, template} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(card, template)
      card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Subtask"})

      context = %{board: board, reader: user}
      refute "Subtask" in titles(run("board: this", context))
      assert "Subtask" in titles(run("board: tree", context))
    end
  end

  describe "one card's tree, and one person's work" do
    test "progress rolls a card's subcards up", %{board: board, user: user} do
      card = card_fixture(hd(board.columns), %{"title" => "Epic"})
      {:ok, template} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(card, template)
      column = hd(Boards.get_board!(sub.id).columns)
      card_fixture(column, %{"title" => "One", "completed" => true})
      card_fixture(column, %{"title" => "Two"})

      assert {:ok, %{kind: :progress, done: 1, total: 2, percent: 50, label: "Epic"}} =
               run("view: progress\ncard: #{card.id}", %{board: board, reader: user})
    end

    test "assigned: me is the reader's own work", %{board: board, user: user, cards: cards} do
      {:ok, _} = Boards.update_card(cards.blocked, %{"assignee_id" => user.id})

      assert titles(run("view: list\nassigned: me", %{board: board, reader: user})) ==
               ["Blocked and soon"]

      assert {:ok, %{kind: :count, count: 0}} =
               run("view: count\nassigned: me", %{
                 board: board,
                 reader: user_fixture("query.nobody@example.com")
               })
    end
  end

  describe "in a page" do
    test "a block is answered when the page is read", %{board: board, user: user} do
      body = """
      Blocked work:

      ```kanban
      view: list
      filter: flag=blocked
      ```
      """

      html = Renderer.to_html(body, board: board, as: user)
      assert html =~ "wiki-query-list"
      assert html =~ "Blocked and soon"

      markdown = Renderer.to_markdown(body, board: board, as: user)
      assert markdown =~ "- Blocked and soon (#"
      refute markdown =~ "filter: flag=blocked"
    end

    test "a bad block is a note on the page, not a broken page", %{board: board, user: user} do
      body = "Before.\n\n```kanban\nfilter: nonsense\n```\n\nAfter.\n"

      html = Renderer.to_html(body, board: board, as: user)
      assert html =~ "wiki-query-error"
      assert html =~ "nothing called"
      assert html =~ "Before."
      assert html =~ "After."
    end

    test "inline expressions answer in a sentence, and unknown ones stay put", %{
      board: board,
      user: user
    } do
      body =
        "There are {{count: flag=blocked}} blocked cards as of {{today}} on {{board.name}}, " <>
          "and {{card.title}} is not ours to fill."

      html = Renderer.to_html(body, board: board, as: user)
      assert html =~ ">1</span>"
      assert html =~ Date.to_iso8601(Date.utc_today())
      assert html =~ "Queries"
      assert html =~ "{{card.title}}"
    end

    test "a block in a code fence that is not kanban is left alone", %{board: board, user: user} do
      html = Renderer.to_html("```\nview: list\n```", board: board, as: user)
      assert html =~ "view: list"
      refute html =~ "wiki-query"
    end

    test "a query in a page a reader can see still answers with their permissions", %{
      board: board,
      user: user
    } do
      other = board_fixture(%{"name" => "Hidden", "code" => "hidden"}, owner: user)
      card_fixture(hd(other.columns), %{"title" => "Secret"})

      reader = user_fixture("query.page.reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      {:ok, page} =
        Wiki.create_page(
          board,
          %{"title" => "Digest", "body" => "```kanban\nview: list\nboard: hidden\n```"},
          user: user
        )

      as_owner = Renderer.to_html(page.body, page: page, board: board, as: user)
      as_reader = Renderer.to_html(page.body, page: page, board: board, as: reader)

      assert as_owner =~ "Secret"
      refute as_reader =~ "Secret"
      assert as_reader =~ "wiki-query-error"
    end
  end
end
