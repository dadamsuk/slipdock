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

  describe "parsing the settings" do
    test "reads each setting, and skips blank lines and comments" do
      assert {:ok, query} =
               Query.parse("""
               # a comment
               view: Table

               board: tree
               done: Hide
               card: #412
               limit: 500
               sort: due_date desc
               group: status
               fields: title ,  priority,
               saved_view: "Blocked work"
               empty: 'Nothing here.'
               unit: month
               filter: flag=blocked
               filter: priority=high
               """)

      assert query.view == "table"
      assert query.board == "tree"
      assert query.done == "hide"
      assert query.card == 412
      # Capped, so a document cannot ask for the whole database.
      assert query.limit == 200
      assert {query.sort, query.dir} == {"due_date", "desc"}
      assert query.group == "completed"
      assert query.fields == ["title", "priority"]
      assert query.saved_view == "Blocked work"
      assert query.empty == "Nothing here."
      assert query.unit == "month"
      # Two filter lines add up rather than the second replacing the first.
      assert [%{"field" => "flag"}, %{"field" => "priority"}] = query.filters
    end

    test "`group: list` is the column, and a plain sort is ascending" do
      assert {:ok, %{group: "column", sort: "title", dir: "asc"}} =
               Query.parse("group: list\nsort: title")

      assert {:ok, %{sort: "title", dir: "asc"}} = Query.parse("sort: title asc")
    end

    test "refuses values it cannot read, saying what to write instead" do
      assert {:error, "done must be all, hide or only"} = Query.parse("done: maybe")
      assert {:error, "card must be a number" <> _} = Query.parse("card: twelve")
      assert {:error, "card must be a number" <> _} = Query.parse("card: 12x")
      assert {:error, "limit must be a positive number"} = Query.parse("limit: 0")
      assert {:error, "limit must be a positive number"} = Query.parse("limit: lots")
      assert {:error, "sort reads" <> _} = Query.parse("sort: due_date sideways")
      assert {:error, "a slipdock block needs some lines in it"} = Query.parse(nil)
      # The first bad line is the one reported.
      assert {:error, "done must be" <> _} = Query.parse("done: maybe\nlimit: 0")
    end

    test "an empty block is the default table of this board" do
      assert {:ok, %Query{view: "table", board: "this", filters: [], limit: nil}} =
               Query.parse("")
    end
  end

  describe "the filter language, operator by operator" do
    test "each operator becomes the runner's condition" do
      today = Date.utc_today()
      iso = &Date.to_iso8601/1

      assert {:ok, [%{"field" => "due_date", "op" => "within_days", "value" => 7}]} =
               Query.parse_filters("due within 7d")

      assert {:ok, [%{"field" => "age_days", "op" => "older_than_days", "value" => 30}]} =
               Query.parse_filters("age older than 30 d")

      assert {:ok, [%{"field" => "due_date", "op" => "is_not_set", "value" => nil}]} =
               Query.parse_filters("due not set")

      assert {:ok, [%{"field" => "completed", "op" => "is", "value" => true}]} =
               Query.parse_filters("done")

      assert {:ok, [%{"field" => "flag", "op" => "is_not", "value" => "blocked"}]} =
               Query.parse_filters("flags != blocked")

      assert {:ok, [%{"field" => "title", "op" => "not_contains", "value" => "draft"}]} =
               Query.parse_filters("title !~ draft")

      assert {:ok, [%{"field" => "tag", "op" => "none_of", "value" => ["a", "b"]}]} =
               Query.parse_filters("tags NOT IN a | b |")

      # `<=` and `>=` on a date are `before`/`after` a day either side.
      assert {:ok, [%{"op" => "before", "value" => before}]} = Query.parse_filters("due <= today")
      assert before == iso.(Date.add(today, 1))

      assert {:ok, [%{"op" => "after", "value" => after_}]} = Query.parse_filters("due >= today")
      assert after_ == iso.(Date.add(today, -1))

      assert {:ok, [%{"op" => "after", "value" => after_}]} =
               Query.parse_filters("start > 2030-01-15")

      assert after_ == "2030-01-15"

      # Anything that is not a date is a plain comparison.
      assert {:ok, [%{"field" => "percent_complete", "op" => "lt", "value" => 50}]} =
               Query.parse_filters("percent < 50")

      assert {:ok, [%{"op" => "lt", "value" => 50}]} = Query.parse_filters("percent <= 50")
      assert {:ok, [%{"op" => "gt", "value" => 50}]} = Query.parse_filters("percent > 50")
      assert {:ok, [%{"op" => "gt", "value" => 50}]} = Query.parse_filters("percent >= 50")
    end

    test "blank clauses are ignored and a bad one halts the rest" do
      assert {:ok, [_]} = Query.parse_filters(" , flag=blocked, ,")
      assert {:ok, []} = Query.parse_filters("")

      assert {:error, "\"due before\" is not a filter" <> _} =
               Query.parse_filters("flag=blocked, due before, priority=high")
    end

    test "an unknown field names the ones that exist" do
      assert {:error, message} = Query.parse_filters("colour=red")
      assert message =~ ~s|nothing called "colour"|
      assert message =~ "due"
      assert "due" in Query.filter_fields()
      assert "due_date" in Query.filter_fields()
    end

    test "resolve_value reads booleans, numbers, dates and relative dates" do
      today = Date.utc_today()

      assert Query.resolve_value("yes") == true
      assert Query.resolve_value("true") == true
      assert Query.resolve_value("no") == false
      assert Query.resolve_value("false") == false
      assert Query.resolve_value("today") == today
      assert Query.resolve_value("tomorrow") == Date.add(today, 1)
      assert Query.resolve_value("yesterday") == Date.add(today, -1)
      assert Query.resolve_value("+7d") == Date.add(today, 7)
      assert Query.resolve_value("-3 D") == Date.add(today, -3)
      assert Query.resolve_value("2030-01-15") == ~D[2030-01-15]
      assert Query.resolve_value("42") == 42
      assert Query.resolve_value(~s| "high" |) == "high"
      assert Query.resolve_value("4.5") == "4.5"
    end
  end

  describe "running, at the edges" do
    test "`board: tree` and `board: this` need a board to start from", %{user: user} do
      assert {:error, "`board: tree` needs a board" <> _} = run("board: tree", %{reader: user})
      assert {:error, "no board here for you to read"} = run("board: this", %{reader: user})
    end

    test "a board named by code is read without a reader, as the system", %{board: board} do
      assert "Later" in titles(run("board: queries", %{board: nil, reader: nil}))
      assert {:error, "there is no board called" <> _} = run("board: nowhere", %{reader: nil})
      assert is_list(titles(run("board: this", %{board: board})))
    end

    test "done: hide and done: only filter on completion", %{board: board, user: user} do
      context = %{board: board, reader: user}

      refute "Finished" in titles(run("done: hide", context))
      assert titles(run("done: only", context)) == ["Finished"]
      assert "Finished" in titles(run("done: all", context))
    end

    test "a table grouped by a field is groups, in the board's own order", %{
      board: board,
      user: user
    } do
      assert {:ok, %{kind: :groups, groups: groups, count: 3}} =
               run("view: table\ngroup: priority", %{board: board, reader: user})

      labels = Enum.map(groups, & &1.label)

      assert Enum.find_index(labels, &(&1 =~ ~r/high/i)) <
               Enum.find_index(labels, &(&1 =~ ~r/low/i))

      assert Enum.all?(groups, &(&1.cards != []))
    end

    test "calendar groups by due date, list keeps the total before the limit", %{
      board: board,
      user: user
    } do
      context = %{board: board, reader: user}

      assert {:ok, %{kind: :groups, groups: groups}} = run("view: calendar", context)
      # Bucketed by due date, so the two dated cards are in different groups.
      group_of = fn title ->
        Enum.find_index(groups, &Enum.any?(&1.cards, fn c -> c.title == title end))
      end

      assert group_of.("Later") != group_of.("Blocked and soon")
      assert length(groups) >= 2

      assert {:ok, %{kind: :list, cards: [_], count: 3}} = run("view: list\nlimit: 1", context)

      assert {:ok, %{kind: :progress, total: 0, percent: 0}} =
               run("view: progress\nfilter: priority=critical", context)
    end

    test "a saved view is embedded, or named as missing", %{board: board, user: user} do
      {:ok, view} =
        Boards.create_saved_view(board, %{
          "name" => "Open only",
          "config" => %{"done" => "hide"}
        })

      context = %{board: board, reader: user}

      refute "Finished" in titles(run(~s|saved_view: "open only"|, context))
      assert "Later" in titles(run(~s|saved_view: "open only"|, context))
      # A block's own `done:` still wins over the view's.
      assert "Finished" in titles(run("saved_view: Open only\ndone: all", context))

      assert {:error, "there is no saved view called \"Nope\" on that board"} =
               run("saved_view: Nope", context)

      # Read access to the board is read access to its views.
      reader = user_fixture("query.viewer@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)
      assert "Later" in titles(run("saved_view: #{view.id}", %{board: board, reader: reader}))
    end

    test "card: N answers for a missing card, an unreadable one and a leaf", %{
      board: board,
      user: user,
      cards: cards
    } do
      assert {:error, "there is no card #987654"} =
               run("view: progress\ncard: 987654", %{board: board, reader: user})

      outsider = user_fixture("query.card.outsider@example.com")

      # The same answer as a card that does not exist.
      assert {:error, "there is no card #" <> _} =
               run("view: progress\ncard: #{cards.later.id}", %{board: board, reader: outsider})

      # A card with no subcards is a tree of one.
      assert {:ok, %{kind: :progress, done: 0, total: 1, percent: 0, label: "Later"}} =
               run("view: progress\ncard: #{cards.later.id}", %{board: board, reader: user})
    end

    test "assigned: names a member, and refuses strangers and a missing reader", %{
      board: board,
      user: user,
      cards: cards
    } do
      {:ok, _} = Boards.update_card(cards.blocked, %{"assignee_id" => user.id})
      context = %{board: board, reader: user}
      handle = Slipdock.Wiki.Links.handle(user)

      assert titles(run("view: list\nassigned: @#{handle}", context)) == ["Blocked and soon"]

      assert titles(run("view: list\nassigned: #{String.upcase(user.email)}", context)) ==
               ["Blocked and soon"]

      assert {:ok, %{kind: :count, count: 1}} = run("view: count\nassigned: me", context)

      assert {:ok, %{kind: :table, rows: [%{cells: ["Blocked and soon", column]}]}} =
               run("view: table\nfields: title, column\nassigned: me", context)

      assert column == hd(board.columns).name

      assert {:ok, %{kind: :count, count: 0}} =
               run("view: count\nassigned: me\nfilter: priority=low", context)

      assert {:error, "nobody on this board answers to \"ghost\""} =
               run("assigned: @ghost", context)

      assert {:error, "`assigned: me` needs to know who is reading"} =
               run("assigned: me", %{board: board, reader: nil})

      assert {:error, "no such person: \"jess\""} = run("assigned: jess", %{reader: user})
    end

    test "assigned: outside `this`/`tree` is every board the person works on", %{
      board: board,
      user: user,
      cards: cards
    } do
      elsewhere = board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere"}, owner: user)
      away = card_fixture(hd(elsewhere.columns), %{"title" => "Away"})
      {:ok, _} = Boards.update_card(away, %{"assignee_id" => user.id})
      {:ok, _} = Boards.update_card(cards.blocked, %{"assignee_id" => user.id})

      here = titles(run("view: list\nassigned: me", %{board: board, reader: user}))
      assert here == ["Blocked and soon"]

      everywhere =
        titles(run("view: list\nassigned: me\nboard: all", %{board: board, reader: user}))

      assert Enum.sort(everywhere) == ["Away", "Blocked and soon"]
    end
  end

  describe "table cells" do
    test "each field reads as the text every renderer shows", %{board: board, user: user} do
      [backlog | _] = board.columns
      tag = tag_fixture(board, "ops")

      card =
        card_fixture(backlog, %{
          "title" => "Cell",
          "priority" => "none",
          "flags" => ["blocked", "waiting"],
          "start_date" => "2030-01-01",
          "due_date" => "2030-01-15",
          "percent_complete" => 40,
          "color" => "red",
          "completed" => true
        })

      {:ok, _} = Boards.update_card(card, %{"assignee_id" => user.id})
      {:ok, _} = Boards.toggle_card_tag(card, tag)

      card =
        Slipdock.Repo.get!(Slipdock.Boards.Card, card.id)
        |> Slipdock.Repo.preload([:column, :assignee, :assignees, :tags, :board])

      assert Query.cell(card, "id") == "##{card.id}"
      assert Query.cell(card, "title") == "Cell"
      assert Query.cell(card, "column") == backlog.name
      assert Query.cell(card, "priority") == ""
      assert Query.cell(card, "assignee") =~ Slipdock.Accounts.User.display_name(user)
      assert Query.cell(card, "flags") == "blocked, waiting"
      assert Query.cell(card, "tags") == "ops"
      assert Query.cell(card, "start_date") == "2030-01-01"
      assert Query.cell(card, "due_date") == "2030-01-15"
      assert Query.cell(card, "completed") == "done"
      assert Query.cell(card, "status") == "done"
      assert Query.cell(card, "percent_complete") == "40%"
      assert Query.cell(card, "color") == "red"
      assert Query.cell(card, "created") =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert Query.cell(card, "updated") =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert Query.cell(card, "board") == board.name
      assert Query.cell(card, "no-such-field") == ""
    end

    test "unloaded or empty associations read as nothing rather than raising" do
      card = %Slipdock.Boards.Card{
        id: 1,
        title: "Bare",
        priority: "high",
        flags: [],
        completed: false
      }

      assert Query.cell(card, "priority") == "high"
      assert Query.cell(card, "tags") == ""
      assert Query.cell(card, "due_date") == ""
      assert Query.cell(card, "completed") == ""
      assert Query.cell(card, "percent_complete") == ""
      assert Query.cell(card, "checklist") == ""
      assert Query.cell(card, "comments") == ""
      assert Query.cell(card, "dependencies") == ""
      assert Query.cell(card, "subcards") == ""
      assert Query.cell(card, "health") == ""
      assert Query.cell(card, "color") == ""
      assert Query.cell(card, "created") == ""
      assert Query.cell(card, "board") == ""
    end

    test "checklist, comments, dependencies and rollup as counts" do
      card = %Slipdock.Boards.Card{
        id: 1,
        title: "Counted",
        checklist_items: [%{done: true}, %{done: false}, %{done: false}],
        comments: [%{}, %{}],
        blocked_by: [%{}],
        blocks: [%{}, %{}],
        rollup: %{total: 4, done: 1, health: "at_risk"}
      }

      assert Query.cell(card, "checklist") == "1/3"
      assert Query.cell(card, "comments") == "2"
      assert Query.cell(card, "dependencies") == "waits on 1, holds up 2"
      assert Query.cell(card, "subcards") == "1/4"
      assert Query.cell(card, "health") == "at_risk"

      assert Query.cell(
               %{card | comments: [], blocked_by: [], rollup: %{total: 0, done: 0}},
               "comments"
             ) ==
               ""

      assert Query.cell(%{card | blocked_by: []}, "dependencies") == "holds up 2"
      assert Query.cell(%{card | rollup: %{total: 0, done: 0}}, "subcards") == ""
    end
  end

  describe "writing a block from a view" do
    test "spells out a view's filters with names, not ids", %{board: board} do
      [backlog, doing | _] = board.columns
      tag = tag_fixture(board, "ops")

      config = %Slipdock.Swimlanes.Config{
        Slipdock.Swimlanes.Config.defaults("table")
        | q: "deploy",
          due: "week",
          done: "hide",
          columns: [to_string(backlog.id), doing.id],
          priorities: ["high", "critical"],
          flags: ["blocked"],
          tags: [tag.id],
          rows: "assignee",
          sort: "due_date",
          dir: "desc",
          fields: ["title", "due_date"]
      }

      block = Query.to_block(config, Boards.get_board!(board.id))

      assert block =~ ~r/^```slipdock\nview: table\nboard: this\n/
      assert block =~ "title ~ deploy"
      assert block =~ "due within 7d"
      assert block =~ "completed=false"
      assert block =~ "list in #{backlog.name}|#{doing.name}"
      assert block =~ "priority in high|critical"
      assert block =~ "flag in blocked"
      assert block =~ "tag in ops"
      assert block =~ "\ngroup: assignee\n"
      assert block =~ "\nsort: due_date desc\n"
      assert block =~ "\nfields: title, due_date\n"
      assert String.ends_with?(block, "```\n")

      # And what it wrote reads back.
      source = block |> String.trim_leading("```slipdock\n") |> String.trim_trailing("```\n")
      assert {:ok, %Query{view: "table", group: "assignee", dir: "desc"}} = Query.parse(source)
    end

    test "each due window and done setting has its clause", %{board: board} do
      base = Slipdock.Swimlanes.Config.defaults("board")
      block = &Query.to_block(%{base | due: &1, done: &2, sort: nil}, board)

      assert block.("overdue", "only") =~ "filter: due < today, completed=true"
      assert block.("today", "all") =~ "filter: due = today\n"
      assert block.("month", "all") =~ "due within 30d"
      assert block.("has", "all") =~ "due set"
      assert block.("none", "all") =~ "due not set"
      assert block.("someday", "all") =~ "due set"

      # Nothing to say is no filter line at all, and a board is not a table.
      plain = block.(nil, "all")
      refute plain =~ "filter:"
      refute plain =~ "fields:"
      refute plain =~ "sort:"
      assert plain =~ "view: board"
    end

    test "names a saved view rather than spelling it out, and maps modes", %{board: board} do
      config = Slipdock.Swimlanes.Config.defaults("table")
      block = Query.to_block(%{config | q: "x"}, board, saved_view: "Blocked work")

      assert block =~ ~s|saved_view: "Blocked work"|
      refute block =~ "filter:"

      for {mode, view} <- [
            {"calendar", "calendar"},
            {"timeline", "timeline"},
            {"swimlanes", "list"},
            {"outline", "list"}
          ] do
        assert Query.to_block(%{config | mode: mode}, board) =~ "view: #{view}\n"
      end
    end
  end

  describe "inline expressions, at the edges" do
    test "now, progress and a card's field", %{board: board, user: user, cards: cards} do
      context = %{board: board, reader: user}

      assert {:ok, now} = Query.inline("now", context)
      assert now =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z$/

      assert {:ok, "2030-01-15"} = Query.inline("today", Map.put(context, :today, ~D[2030-01-15]))
      assert {:ok, "0/1 (0%)"} = Query.inline("progress: ##{cards.later.id}", context)
      assert {:ok, "Later"} = Query.inline("card:#{cards.later.id}.title", context)
      assert {:ok, "low"} = Query.inline("card: ##{cards.later.id}.priority", context)
      assert {:ok, ""} = Query.inline("card:#{cards.done.id}.due_date", context)
    end

    # `{{card:N.field}}` loaded the card with only some of its associations,
    # so the board, checklist, comments and dependencies always read as "".
    test "a card's field reads what the card has, whichever field it is", %{
      board: board,
      user: user,
      cards: cards
    } do
      context = %{board: board, reader: user}
      later = cards.later

      {:ok, _} = Boards.add_checklist_item(later, "one")
      {:ok, _} = Boards.add_comment(later, "a note")
      {:ok, _} = Boards.add_dependency(later, cards.blocked)

      assert {:ok, "Queries"} = Query.inline("card:#{later.id}.board", context)
      assert {:ok, "0/1"} = Query.inline("card:#{later.id}.checklist", context)
      assert {:ok, "1"} = Query.inline("card:#{later.id}.comments", context)
      assert {:ok, "waits on 1"} = Query.inline("card:#{later.id}.dependencies", context)
      assert {:ok, "holds up 1"} = Query.inline("card:#{cards.blocked.id}.dependencies", context)
    end

    test "anything it cannot answer is :error, so the text stays as written", %{
      board: board,
      user: user,
      cards: cards
    } do
      context = %{board: board, reader: user}
      outsider = user_fixture("query.inline.outsider@example.com")

      assert :error = Query.inline("board.name", %{reader: user})
      assert :error = Query.inline("count: nonsense", context)
      assert :error = Query.inline("progress: 987654", context)
      assert :error = Query.inline("card:987654.title", context)

      assert :error =
               Query.inline("card:#{cards.later.id}.title", %{board: board, reader: outsider})

      assert :error = Query.inline("card.title", context)
    end
  end
end
