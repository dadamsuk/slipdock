defmodule SlipdockWeb.WikiLiveTest do
  @moduledoc "Reading, writing and the history of a board's wiki in the browser."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Wiki}

  # A placed page's panel is a LiveComponent; what it is pushed goes to it.
  defp page_panel(view), do: with_target(view, "#board-page")

  setup %{user: user} do
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook"}, owner: user)
    %{board: board}
  end

  test "the index lists what has been written, and links to it", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "Retry policy", "body" => "We retry three times."})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    assert has_element?(view, "a[href='/boards/#{board.id}/wiki/#{page.slug}']")
    assert render(view) =~ "Retry policy"
  end

  test "an empty wiki says so and offers the first page", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki")

    assert render(view) =~ "No pages yet"
    assert has_element?(view, "a[href='/boards/#{board.id}/wiki/new']")
  end

  test "a page renders its Markdown, not its source", %{conn: conn, board: board} do
    page =
      page_fixture(board, %{
        "title" => "Runbook",
        "body" => "## Rollback\n\n| step | who |\n|---|---|\n| one | ops |"
      })

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    assert html =~ "<h2 id=\"rollback\""
    assert has_element?(view, ".wiki-prose table")
    assert has_element?(view, "a", "History")
  end

  # #325: a card naming the page is a backlink with no page behind it, and
  # the "Linked from" list crashed the whole view reaching for its title.
  test "a page linked from a card and from a page names both under Linked from", %{
    conn: conn,
    board: board,
    user: user
  } do
    page = page_fixture(board, %{"title" => "Retry policy"}, user: user)
    page_fixture(board, %{"title" => "Runbook", "body" => "See [[Retry policy]]."}, user: user)
    card = card_fixture(hd(Boards.get_board!(board.id).columns), %{"title" => "Ship retries"})
    {:ok, _} = Boards.add_comment(card, "blocked on [[Retry policy]]")

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    assert html =~ "Linked from"
    assert has_element?(view, "a[href='/boards/#{board.id}/cards/#{card.id}']", "Ship retries")
    assert has_element?(view, "a[href='/boards/#{board.id}/wiki/runbook']", "Runbook")
  end

  test "writing a page creates it and lands on it", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/new")

    assert {:error, {:live_redirect, %{to: path}}} =
             view
             |> form("#page-form", page: %{title: "Deploys", body: "# How we ship"})
             |> render_submit()

    assert path == "/boards/#{board.id}/wiki/deploys"
    assert {:ok, %{title: "Deploys"}} = Wiki.find_page(board, "deploys")
  end

  test "the editor previews as you type", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "Notes", "body" => "plain"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

    html =
      view
      |> form("#page-form")
      |> render_change(page: %{title: "Notes", body: "## A heading"})

    assert html =~ "<h2 id=\"a-heading\""
  end

  test "a save against a version someone else moved on from is refused, not applied", %{
    conn: conn,
    board: board,
    user: user
  } do
    page = page_fixture(board, %{"title" => "Shared", "body" => "mine"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

    other = user_fixture("live.other@example.com")
    {:ok, _} = Access.grant(board, other, "write", user)
    {:ok, _} = Wiki.update_page(page, %{"body" => "theirs"}, user: other)

    html =
      view
      |> form("#page-form", page: %{title: "Shared", body: "mine, edited"})
      |> render_submit()

    assert html =~ "changed while you were writing"
    assert Wiki.get_page!(page.id).body == "theirs"
  end

  test "history lists every save and one can be put back", %{
    conn: conn,
    board: board,
    user: user
  } do
    page = page_fixture(board, %{"title" => "Doc", "body" => "first"})
    other = user_fixture("live.historian@example.com")
    {:ok, _} = Access.grant(board, other, "write", user)
    {:ok, page} = Wiki.update_page(page, %{"body" => "second"}, user: other)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")

    [newest, oldest] = Wiki.list_revisions(page)
    assert has_element?(view, "a[href$='/history/#{oldest.id}']")

    # The diff itself, not just the body: the marker and the line it belongs
    # to, which a template that stopped interpolating would silently lose.
    {:ok, _, latest_html} =
      live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history/#{newest.id}")

    assert latest_html =~ ~r/data-op="del"[^>]*>.*first/s
    assert latest_html =~ ~r/data-op="ins"[^>]*>.*second/s

    {:ok, revision_view, html} =
      live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history/#{oldest.id}")

    assert html =~ "Nothing before this version"
    assert has_element?(revision_view, ~s|td[data-op="ins"]|, "first")
    refute has_element?(revision_view, ~s|td[data-op="del"]|)

    assert {:error, {:live_redirect, _}} =
             revision_view |> element("button", "Restore this version") |> render_click()

    assert Wiki.get_page!(page.id).body == "first"
  end

  describe "comparing versions side by side" do
    setup %{board: board, user: user} do
      page = page_fixture(board, %{"title" => "Spec", "body" => "the quick brown fox\nkept"})
      editor = user_fixture("live.differ@example.com")
      {:ok, _} = Access.grant(board, editor, "write", user)
      # A different hand each time, so every save is its own revision.
      {:ok, page} = Wiki.update_page(page, %{"body" => "the quick red fox\nkept"}, user: editor)

      {:ok, page} =
        Wiki.update_page(page, %{"body" => "the quick red fox\nkept\nadded"}, user: user)

      [newest, middle, oldest] = Wiki.list_revisions(page)
      %{page: page, newest: newest, middle: middle, oldest: oldest}
    end

    test "an edited line sits beside its replacement, the changed word picked out", %{
      conn: conn,
      board: board,
      page: page,
      middle: middle
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history/#{middle.id}")

      assert has_element?(view, "#split-diff th", "(the version before)")
      assert has_element?(view, ~s|td[data-op="del"] span.diff-word|, "brown")
      assert has_element?(view, ~s|td[data-op="ins"] span.diff-word|, "red")
      # The unchanged line is on both sides, not marked either way.
      assert has_element?(view, ~s|td[data-op="eq"]|, "kept")
    end

    test "the picker compares any two, older on the left whichever way they are ticked", %{
      conn: conn,
      board: board,
      page: page,
      newest: newest,
      oldest: oldest
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")

      # Ticked back to front: the newest as "from", the oldest as "to".
      view
      |> form("#compare-form", %{"from" => newest.id, "to" => oldest.id})
      |> render_submit()

      assert_patch(
        view,
        ~p"/boards/#{board}/wiki/#{page.slug}/history/#{newest.id}?against=#{oldest.id}"
      )

      assert has_element?(view, ~s|td[data-op="del"]|, "brown")
      assert has_element?(view, ~s|td[data-op="ins"]|, "added")
      assert has_element?(view, "#split-diff th", "(current)")
      refute has_element?(view, "#split-diff th", "(the version before)")
    end

    test "the same version twice, or one from another page, is refused", %{
      conn: conn,
      board: board,
      page: page,
      newest: newest
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")

      html =
        view
        |> form("#compare-form", %{"from" => newest.id, "to" => newest.id})
        |> render_submit()

      assert html =~ "Pick two different versions to compare."

      html = render_submit(view, "compare", %{"from" => "999999", "to" => to_string(newest.id)})
      assert html =~ "Pick two versions from the list to compare."
    end

    test "Compare with current shows an old version against the page as it is", %{
      conn: conn,
      board: board,
      page: page,
      newest: newest,
      oldest: oldest
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history/#{oldest.id}")

      view |> element("a", "Compare with current") |> render_click()

      assert_patch(
        view,
        ~p"/boards/#{board}/wiki/#{page.slug}/history/#{newest.id}?against=#{oldest.id}"
      )

      # Already on the current version, there is nothing to compare it with.
      refute has_element?(view, "a", "Compare with current")
    end

    test "an unknown version to compare with falls back to the one before", %{
      conn: conn,
      board: board,
      page: page,
      newest: newest
    } do
      {:ok, view, html} =
        live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history/#{newest.id}?against=999999")

      assert html =~ "No such version to compare with"
      assert has_element?(view, "#split-diff th", "(the version before)")
      assert has_element?(view, ~s|td[data-op="ins"]|, "added")
    end

    test "comparing a version with itself says there is no change", %{
      conn: conn,
      board: board,
      page: page,
      newest: newest
    } do
      {:ok, _view, html} =
        live(
          conn,
          ~p"/boards/#{board}/wiki/#{page.slug}/history/#{newest.id}?against=#{newest.id}"
        )

      assert html =~ "No change between these two versions."
    end

    test "long unchanged stretches fold behind a button that opens them", %{
      conn: conn,
      board: board,
      user: user
    } do
      body = Enum.map_join(1..20, "\n", &"line #{&1}")
      page = page_fixture(board, %{"title" => "Long", "body" => body})
      other = user_fixture("live.folder@example.com")
      {:ok, _} = Access.grant(board, other, "write", user)
      {:ok, page} = Wiki.update_page(page, %{"body" => body <> "\nline 21"}, user: other)
      [newest | _] = Wiki.list_revisions(page)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history/#{newest.id}")

      assert has_element?(view, "#split-diff button", "17 unchanged lines")
      # Folded rows are rendered, hidden, so opening them is a client-side show.
      assert has_element?(view, "#split-diff tbody.hidden td", "line 1")
      assert has_element?(view, ~s|td[data-op="ins"]|, "line 21")
    end
  end

  test "a reader sees the page but no way to change it", %{conn: _conn, board: board, user: user} do
    page = page_fixture(board, %{"title" => "Readable"})
    reader = user_fixture("live.reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{board}/wiki/#{page.slug}")

    refute has_element?(view, "a[href$='/edit']")
    refute has_element?(view, "a[href$='/wiki/new']")
  end

  test "a draft stays out of a reader's sight", %{board: board, user: user} do
    draft = page_fixture(board, %{"title" => "Half written", "status" => "draft"})
    reader = user_fixture("live.draft.reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{board}/wiki")
    refute render(view) =~ "Half written"

    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn_as(reader), ~p"/boards/#{board}/wiki/#{draft.slug}")

    assert path == "/boards/#{board.id}/wiki"
  end

  test "a passage becomes a card, and the page says where it went", %{
    conn: conn,
    board: board
  } do
    page =
      page_fixture(board, %{
        "title" => "Findings",
        "body" => "Intro.\n\nRetries are wrong\nThey never stop.\n"
      })

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

    render_hook(view, "card_from_selection", %{"text" => "Retries are wrong\nThey never stop."})

    assert Wiki.get_page!(page.id).body =~ ~r/\(#\d+\)/
    assert has_element?(view, "#selection-to-card")
  end

  test "the card panel lists what has been written about the card", %{
    conn: conn,
    board: board
  } do
    card = card_fixture(hd(board.columns), %{"title" => "Ship it"})

    page =
      page_fixture(board, %{"title" => "Ship spec", "body" => "About ##{card.id}."})

    {:ok, _} = Wiki.pin(page, {:card, card})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    assert has_element?(view, "#card-docs")
    assert has_element?(view, "#card-docs a", "Ship spec")
  end

  test "write it up starts a page for the card and opens it", %{conn: conn, board: board} do
    card = card_fixture(hd(board.columns), %{"title" => "Fix retries"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("#card-docs button", "Write it up") |> render_click()

    assert path =~ "/wiki/fix-retries/edit"
    assert [%{pinned: true}] = Wiki.pages_for_card(card)
  end

  test "publishing gives a public page, and its answers are a snapshot", %{
    conn: conn,
    board: board
  } do
    card_fixture(hd(board.columns), %{"title" => "Blocked one", "flags" => ["blocked"]})

    page =
      page_fixture(board, %{
        "title" => "Status",
        "body" => "Blocked: {{count: flag=blocked}}.\n\nSee [[Status]] itself.\n"
      })

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    render_click(view, "publish")

    published = Wiki.get_page!(page.id)
    assert published.public_token

    # Anonymous, no account, and nothing followable.
    {:ok, _public, html} = live(build_conn(), ~p"/w/#{published.public_token}")
    assert html =~ ~s|Blocked: <span class="wiki-inline">1</span>.|
    assert html =~ "wiki-static"
    refute html =~ "href=\"/boards/"

    # The answer does not move once published.
    card_fixture(hd(board.columns), %{"title" => "Another", "flags" => ["blocked"]})
    {:ok, _public, html} = live(build_conn(), ~p"/w/#{published.public_token}")
    assert html =~ ~s|Blocked: <span class="wiki-inline">1</span>.|

    render_click(view, "unpublish")

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(build_conn(), ~p"/w/#{published.public_token}")
  end

  test "the wiki can be downloaded as Markdown", %{conn: conn, board: board} do
    page_fixture(board, %{"title" => "Charter", "body" => "# Charter"})

    response = get(conn, ~p"/boards/#{board}/wiki.zip")
    assert response.status == 200
    assert {:ok, entries} = :zip.list_dir(response.resp_body)
    names = for {:zip_file, path, _, _, _, _} <- entries, do: to_string(path)
    assert "Charter.md" in names
  end

  test "one page can be downloaded as Markdown", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "Charter", "body" => "# Charter"})

    response = get(conn, ~p"/boards/#{board}/wiki/#{page.slug}/page.md")

    assert response.status == 200
    assert response.resp_body =~ "title: Charter"
    assert response.resp_body =~ "# Charter"

    assert get(conn, ~p"/boards/#{board}/wiki/nonesuch/page.md").status == 404
  end

  describe "deleting a page for good" do
    test "the owner can purge it, and its children are kept", %{conn: conn, board: board} do
      page = page_fixture(board, %{"title" => "Retry policy"})

      {:ok, child} =
        Wiki.create_page(board, %{"title" => "Backoff", "parent_id" => page.id},
          user: board.owner_id && Slipdock.Accounts.get_user!(board.owner_id)
        )

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      # The warning says where the children end up, since they are not deleted.
      assert has_element?(view, "button[phx-click='delete_page'][data-confirm*='1 page']")

      render_click(view, "delete_page")

      assert Wiki.get_page(page.id) == nil
      assert Wiki.get_page!(child.id).parent_id == nil
    end

    test "someone who can write but does not own the board cannot", %{board: board, user: owner} do
      page = page_fixture(board, %{"title" => "Retry policy"})
      writer = user_fixture("writer@example.com")
      {:ok, _} = Access.grant(board, writer, "write", owner)

      conn = log_in_user(build_conn(), writer)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      refute has_element?(view, "button[phx-click='delete_page']")
      assert render(view) =~ "Only the board&#39;s owner can delete a page for good."

      render_click(view, "delete_page")

      assert Wiki.get_page!(page.id)
    end
  end

  test "a page can be put on the board and taken off again", %{conn: conn, board: board} do
    page = page_fixture(board, %{"title" => "The spec"})
    [todo | _] = board.columns

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
    assert render(view) =~ "Not on the board."

    render_click(element(view, "button[phx-value-column='#{todo.id}']"))
    assert Wiki.get_page!(page.id).column_id == todo.id
    assert render(view) =~ "On the board in"

    render_click(view, "unplace")
    refute Wiki.get_page!(page.id).column_id
  end

  test "a placed page shows in the list and can be dragged", %{conn: conn, board: board} do
    [todo, doing | _] = board.columns
    card = card_fixture(todo, %{"title" => "The work"})
    page = page_fixture(board, %{"title" => "The spec"})
    {:ok, _} = Wiki.place(page, todo)

    {:ok, view, html} = live(conn, ~p"/boards/#{board}")

    assert html =~ "The spec"
    assert has_element?(view, "#page-#{page.id}[data-id='page-#{page.id}']")

    # The same drag event a card sends, with the page's own id.
    render_hook(view, "move_card", %{
      "id" => "page-#{page.id}",
      "from" => to_string(todo.id),
      "to" => to_string(doing.id),
      "before" => nil
    })

    assert Wiki.get_page!(page.id).column_id == doing.id
    assert Boards.active_items(todo.id) == [card: card.id]

    # And off the board from its panel.
    render_click(view, "open_page", %{"id" => page.id})
    render_click(page_panel(view), "unplace_page", %{"id" => page.id})
    refute Wiki.get_page!(page.id).column_id
  end

  test "the document icon opens the page, and the tile opens its panel", %{
    conn: conn,
    board: board
  } do
    [todo | _] = board.columns
    page = page_fixture(board, %{"title" => "The spec", "priority" => "critical"})
    {:ok, _} = Wiki.place(page, todo)

    {:ok, view, html} = live(conn, ~p"/boards/#{board}")

    # One click on the icon goes straight to the document.
    assert html =~ ~s|href="/boards/#{board.id}/wiki/#{page.slug}"|
    assert has_element?(view, "#page-#{page.id} a[href$='/wiki/#{page.slug}']")

    # …and everything else behaves like a card: the tile opens a panel, and
    # the facets are drawn there the way a card's are.
    assert html =~ "Critical"

    render_click(view, "open_page", %{"id" => page.id})
    assert has_element?(view, "#page-panel")
    assert render(view) =~ "Open the document"
  end

  test "the panel sets the facets a card has", %{conn: conn, board: board} do
    [todo | _] = board.columns
    page = page_fixture(board, %{"title" => "The spec"})
    {:ok, _} = Wiki.place(page, todo)

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}?#{[page: page.id]}")
    assert has_element?(view, "#page-panel-form")

    view
    |> form("#page-panel-form")
    |> render_change(page: %{priority: "high", percent_complete: "40", due_date: "2026-10-09"})

    reread = Wiki.get_page!(page.id)
    assert reread.priority == "high"
    assert reread.percent_complete == 40
    assert reread.due_date == ~D[2026-10-09]

    render_click(page_panel(view), "page_toggle_flag", %{"flag" => "blocked"})
    assert Wiki.get_page!(page.id).flags == ["blocked"]

    render_click(page_panel(view), "page_toggle_flag", %{"flag" => "blocked"})
    assert Wiki.get_page!(page.id).flags == []
  end

  test "a reader sees the panel but cannot change it", %{board: board, user: user} do
    [todo | _] = board.columns
    page = page_fixture(board, %{"title" => "The spec"})
    {:ok, _} = Wiki.place(page, todo)

    reader = user_fixture("facets.reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    {:ok, view, html} = live(conn_as(reader), ~p"/boards/#{board}?#{[page: page.id]}")

    assert html =~ "read-only access to this page"
    refute has_element?(view, "#page-panel-form")

    render_click(page_panel(view), "page_toggle_flag", %{"flag" => "blocked"})
    assert Wiki.get_page!(page.id).flags == []
  end

  test "a placed page stands beside the cards in the other views", %{conn: conn, board: board} do
    [todo | _] = board.columns
    card_fixture(todo, %{"title" => "The work", "priority" => "high"})
    page = page_fixture(board, %{"title" => "The spec", "priority" => "critical"})
    {:ok, _} = Wiki.place(page, todo)

    for path <- [
          ~p"/boards/#{board}/table",
          ~p"/boards/#{board}/swimlanes",
          ~p"/boards/#{board}/timeline",
          ~p"/boards/#{board}/calendar"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "The spec", "expected the page in #{path}"
      assert html =~ "The work", "expected the card in #{path}"
    end
  end

  test "a reader cannot move a placed page", %{board: board, user: user} do
    [todo, doing | _] = board.columns
    page = page_fixture(board, %{"title" => "The spec"})
    {:ok, _} = Wiki.place(page, todo)

    reader = user_fixture("placement.reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    {:ok, view, html} = live(conn_as(reader), ~p"/boards/#{board}")
    assert html =~ "The spec"

    render_hook(view, "move_card", %{
      "id" => "page-#{page.id}",
      "from" => to_string(todo.id),
      "to" => to_string(doing.id),
      "before" => nil
    })

    assert Wiki.get_page!(page.id).column_id == todo.id
  end

  test "a draft on the board is hidden from a reader", %{board: board, user: user} do
    [todo | _] = board.columns
    draft = page_fixture(board, %{"title" => "Half written", "status" => "draft"})
    {:ok, _} = Wiki.place(draft, todo)

    reader = user_fixture("placement.draft@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    {:ok, _view, as_writer} = live(conn_as(user), ~p"/boards/#{board}")
    {:ok, _view, as_reader} = live(conn_as(reader), ~p"/boards/#{board}")

    assert as_writer =~ "Half written"
    refute as_reader =~ "Half written"
  end

  test "someone with no access to the board is turned away", %{board: board} do
    outsider = user_fixture("live.outsider@example.com")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn_as(outsider), ~p"/boards/#{board}/wiki")
  end

  describe "the card contents a page carries" do
    setup %{board: board} do
      %{page: page_fixture(board, %{"title" => "Retry policy"})}
    end

    test "the document's own view takes a comment, a tick box and a report", %{
      conn: conn,
      board: board,
      page: page
    } do
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert html =~ "Comments"
      assert html =~ "Checklist"
      assert html =~ "Status updates"

      render_submit(view, "add_comment", %{"body" => "reads well"})
      assert render(view) =~ "reads well"

      render_submit(view, "add_check", %{"text" => "outline it"})
      assert render(view) =~ "outline it"

      render_submit(view, "add_status_update", %{"health" => "at_risk", "body" => "stalled"})
      assert render(view) =~ "stalled"

      reloaded = Slipdock.Repo.preload(Wiki.get_page!(page.id), Wiki.board_preloads())
      assert [%{body: "reads well"}] = reloaded.comments
      assert [%{text: "outline it", done: false}] = reloaded.checklist_items
      assert Slipdock.Boards.Card.stated_health(reloaded) == "at_risk"
    end

    test "a reader may look but not write", %{board: board, page: page, user: user} do
      reader = user_fixture("wiki.contents.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", user)
      conn = conn_as(reader)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")
      assert html =~ "Comments"
      refute has_element?(view, "form[phx-submit='add_comment']")

      render_submit(view, "add_comment", %{"body" => "sneaky"})
      assert Slipdock.Repo.preload(Wiki.get_page!(page.id), :comments).comments == []
    end

    test "the board's panel writes to the page, not to any card", %{
      conn: conn,
      board: board,
      page: page
    } do
      [todo | _] = board.columns
      card = card_fixture(todo, %{"title" => "The work"})
      {:ok, _} = Wiki.place(page, todo)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      render_click(view, "open_page", %{"id" => page.id})

      render_submit(page_panel(view), "add_comment", %{"body" => "on the document"})
      render_submit(page_panel(view), "add_check", %{"text" => "a page's item"})

      page = Slipdock.Repo.preload(Wiki.get_page!(page.id), Wiki.board_preloads())
      assert [%{body: "on the document"}] = page.comments
      assert [%{text: "a page's item"}] = page.checklist_items

      # The open card is a different subject, and stays untouched.
      card = Slipdock.Boards.get_card!(card.id)
      assert card.comments == []
      assert card.checklist_items == []
    end
  end

  describe "the wiki keeps the board's bar" do
    test "the view selector says Wiki, and the filters narrow the tree", %{
      conn: conn,
      board: board
    } do
      page_fixture(board, %{"title" => "Urgent spec", "priority" => "critical"})
      page_fixture(board, %{"title" => "Idle notes"})

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki")

      # The same switcher the card views carry, naming the wiki as current.
      assert html =~ "Search page/folder titles…"
      assert has_element?(view, "#view-menu", "Wiki")
      assert has_element?(view, ~s|#view-menu a[href="/boards/#{board.id}/table"]|)

      assert render(view) =~ "Urgent spec"
      assert render(view) =~ "Idle notes"

      # A page answers the card filters, because it carries the card facets.
      render_click(view, "filter_priority", %{"priority" => "critical"})
      assert render(view) =~ "Urgent spec"
      refute render(view) =~ "Idle notes"

      render_click(view, "clear_filters", %{})
      assert render(view) =~ "Idle notes"

      render_change(view, "search", %{"q" => "idle"})
      refute render(view) =~ "Urgent spec"
    end

    test "display options say what the tree lists at all", %{conn: conn, board: board} do
      page_fixture(board, %{"title" => "A draft", "status" => "draft"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
      assert render(view) =~ "A draft"

      render_click(view, "toggle_show", %{"what" => "drafts"})
      refute render(view) =~ "A draft"
    end
  end

  # #323: a long page ran out past the bottom of the app, onto the bare page
  # behind it. The panes have to sit in a column the height of the layout's
  # <main> to scroll inside it, and the scroll pane has to be positioned so
  # the sr-only (absolute) radios in it cannot stretch the document.
  describe "a long page stays inside the app" do
    @column "#wiki-shell.flex.h-full.flex-col"
    @pane "#{@column} > div.flex.min-h-0.flex-1.overflow-hidden > main#wiki-main"

    test "the page scrolls in its own pane, under the bar", %{conn: conn, board: board} do
      body = Enum.map_join(1..80, "\n\n", &"## Section #{&1}\n\nParagraph #{&1}.")
      page = page_fixture(board, %{"title" => "Very long", "body" => body})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert has_element?(view, "#{@column} > div #view-menu")
      assert has_element?(view, "#{@pane}.relative.overflow-y-auto.min-w-0")
      assert has_element?(view, "#{@pane} .wiki-prose", "Section 80")
      assert has_element?(view, "#{@column} #wiki-tree.overflow-y-auto")
    end

    test "the status radios sit inside the positioned pane", %{conn: conn, board: board} do
      page = page_fixture(board, %{"title" => "Has a status"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert has_element?(view, "#{@pane}.relative input.sr-only[type=radio]")
      refute has_element?(view, "body > input.sr-only[type=radio]")
    end

    test "the index and the editor share the same column", %{
      conn: conn,
      board: board
    } do
      page = page_fixture(board, %{"title" => "Edit me"})

      {:ok, index, _} = live(conn, ~p"/boards/#{board}/wiki")
      assert has_element?(index, @pane, "Edit me")

      {:ok, editor, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
      assert has_element?(editor, "#{@pane} form")
    end
  end
end
