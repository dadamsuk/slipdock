defmodule SlipdockWeb.API.PageControllerTest do
  @moduledoc """
  `SlipdockWeb.API.PageController` where agents and the CLI trip: the
  refusals and the less-travelled options. `pages_test.exs` and its siblings
  cover the main road; these cover a read-only or board-scoped token, a page,
  card, template, folder or revision that is not there, a body that is
  missing or malformed, and the listing and export filters an agent reaches
  for once the wiki has grown.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Pages API", "code" => "pagesapi"}, owner: user)
    conn = put_req_header(conn, "accept", "application/json")
    %{conn: conn, board: board}
  end

  defp create(conn, body) do
    conn |> post("/api/boards/pagesapi/pages", body) |> json_response(201) |> Map.fetch!("page")
  end

  defp titles(conn, query) do
    conn
    |> get("/api/boards/pagesapi/pages?" <> query)
    |> json_response(200)
    |> Map.fetch!("pages")
    |> Enum.map(& &1["title"])
    |> Enum.sort()
  end

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  describe "listing filters" do
    setup %{conn: conn} do
      parent = create(conn, %{title: "Deploys"})
      create(conn, %{title: "Rollback", parent: parent["code"], folder: "Ops"})
      create(conn, %{title: "Spec skeleton", template: true})
      gone = create(conn, %{title: "Old notes"})
      conn |> delete("/api/pages/#{gone["id"]}") |> json_response(200)
      %{parent: parent}
    end

    test "by folder: a name, none, and an unknown one ignored", %{conn: conn} do
      assert titles(conn, "folder=Ops") == ["Rollback"]
      assert titles(conn, "folder=none") == ["Deploys", "Spec skeleton"]
      assert titles(conn, "folder=") == ["Deploys", "Rollback", "Spec skeleton"]
      assert titles(conn, "folder=Nowhere") == ["Deploys", "Rollback", "Spec skeleton"]
    end

    test "by parent: an id, root, and nonsense ignored", %{conn: conn, parent: parent} do
      assert titles(conn, "parent=#{parent["id"]}") == ["Rollback"]
      assert titles(conn, "parent=none") == ["Deploys", "Spec skeleton"]
      assert titles(conn, "parent=") == ["Deploys", "Rollback", "Spec skeleton"]
      assert titles(conn, "parent=W-x") == ["Deploys", "Rollback", "Spec skeleton"]
    end

    test "templates on their own or left out, and archived ones only when asked", %{conn: conn} do
      assert titles(conn, "template=true") == ["Spec skeleton"]
      assert titles(conn, "template=false") == ["Deploys", "Rollback"]
      assert titles(conn, "template=") == ["Deploys", "Rollback", "Spec skeleton"]
      assert titles(conn, "archived=yes") == ["Old notes"]
      assert titles(conn, "archived=all") == ["Deploys", "Old notes", "Rollback", "Spec skeleton"]
    end
  end

  describe "a token that may not" do
    setup %{conn: conn} do
      %{page: create(conn, %{title: "Runbook", body: "one"})}
    end

    test "read-only: reads the page, cannot save over it", %{user: user, page: page} do
      conn = with_token(user, scope: "read")

      assert %{"page" => %{"body" => "one"}} =
               conn |> get("/api/pages/#{page["id"]}") |> json_response(200)

      assert %{"error" => error} =
               conn |> patch("/api/pages/#{page["id"]}", %{body: "two"}) |> json_response(403)

      assert error =~ "read-only"
      assert Wiki.get_page!(page["id"]).body == "one"
    end

    test "board-scoped elsewhere: refused, and told the scope did it", %{user: user, page: page} do
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: user)
      conn = with_token(user, scope_boards: [elsewhere.id])

      assert %{"error" => error} = conn |> get("/api/pages/#{page["id"]}") |> json_response(403)
      assert error =~ "scope"

      assert %{"error" => error} =
               conn
               |> post("/api/pages/#{page["id"]}/append", %{body: "more"})
               |> json_response(403)

      assert error =~ "scope"
      assert conn |> get("/api/boards/pagesapi/pages/export") |> json_response(403)
      assert Wiki.get_page!(page["id"]).body == "one"
    end
  end

  describe "writing one page" do
    setup %{conn: conn} do
      %{page: create(conn, %{title: "Runbook", body: "# Runbook\n\n## Deploy\n\nship it"})}
    end

    test "an unknown page is a 404", %{conn: conn} do
      assert %{"error" => error} = conn |> get("/api/pages/W-999999") |> json_response(404)
      assert error =~ "not found"
    end

    test "a parent that is not there is a 404 and no page is made", %{conn: conn} do
      assert %{"error" => error} =
               conn
               |> post("/api/boards/pagesapi/pages", %{title: "Orphan", parent: "No Such Page"})
               |> json_response(404)

      assert error =~ "No Such Page"
      assert titles(conn, "q=Orphan") == []
    end

    test "a folder named by an id that is not there is refused", %{conn: conn, page: page} do
      assert conn
             |> patch("/api/pages/#{page["id"]}", %{folder: 999_999_999})
             |> json_response(404)
    end

    test "assignee \"\" unassigns", %{conn: conn, page: page, user: user} do
      assert %{"page" => %{"assignee" => %{"email" => email}}} =
               conn
               |> patch("/api/pages/#{page["id"]}", %{assignee: user.email})
               |> json_response(200)

      assert email == user.email

      assert %{"page" => %{"assignee" => nil}} =
               conn |> patch("/api/pages/#{page["id"]}", %{assignee: ""}) |> json_response(200)
    end

    test "fields: unknown is a 404, a bad value or a non-object a 422", %{
      conn: conn,
      board: board,
      page: page
    } do
      {:ok, _} = Slipdock.Fields.create_field(board, %{"name" => "Effort", "kind" => "number"})

      assert %{"error" => "field size not found"} =
               conn
               |> patch("/api/pages/#{page["id"]}", %{fields: %{"size" => 1}})
               |> json_response(404)

      assert %{"error" => _} =
               conn
               |> patch("/api/pages/#{page["id"]}", %{fields: %{"effort" => "lots"}})
               |> json_response(422)

      assert %{"error" => "fields must be an object"} =
               conn
               |> patch("/api/pages/#{page["id"]}", %{fields: ["effort"]})
               |> json_response(422)
    end

    test "append takes `text` as well as `body`, and refuses neither", %{conn: conn, page: page} do
      assert %{"page" => %{"body" => body}} =
               conn
               |> post("/api/pages/#{page["id"]}/append", %{text: "Done."})
               |> json_response(200)

      assert body =~ "Done."

      assert %{"error" => "pass the text as `body`"} =
               conn |> post("/api/pages/#{page["id"]}/append", %{}) |> json_response(400)

      assert %{"error" => "pass the text as `body`"} =
               conn
               |> put("/api/pages/#{page["id"]}/section/Deploy", %{body: 42})
               |> json_response(400)
    end

    test "a stale base_hash on a section replace is a 409 and nothing is written", %{
      conn: conn,
      page: page
    } do
      conn |> post("/api/pages/#{page["id"]}/append", %{body: "later"}) |> json_response(200)
      before = Wiki.get_page!(page["id"]).body

      assert %{"current" => %{"content_hash" => _}} =
               conn
               |> put("/api/pages/#{page["id"]}/section/Deploy", %{
                 body: "## Deploy\n\nrewritten",
                 base_hash: page["content_hash"]
               })
               |> json_response(409)

      assert Wiki.get_page!(page["id"]).body == before
    end

    test "render as text strips the markup", %{conn: conn, page: page} do
      conn
      |> patch("/api/pages/#{page["id"]}", %{
        body: "# Title\n\n**Bold** and [a link](https://x.y)"
      })
      |> json_response(200)

      assert %{"format" => "text", "body" => body} =
               conn |> get("/api/pages/#{page["id"]}/render?format=text") |> json_response(200)

      assert body =~ "Title"
      assert body =~ "Bold and a link"
      refute body =~ "**"
      refute body =~ "https://x.y"
    end
  end

  describe "moving" do
    setup %{conn: conn} do
      a = create(conn, %{title: "A"})
      b = create(conn, %{title: "B"})
      c = create(conn, %{title: "C"})
      %{a: a, b: b, c: c}
    end

    defp root_order(conn) do
      conn
      |> get("/api/boards/pagesapi/pages?tree=true")
      |> json_response(200)
      |> Map.fetch!("pages")
      |> Enum.map(& &1["title"])
    end

    test "position takes top, bottom, a number, a numeric string and else the end", %{
      conn: conn,
      a: a,
      c: c
    } do
      move = fn page, position ->
        conn
        |> post("/api/pages/#{page["id"]}/move", %{parent: "root", position: position})
        |> json_response(200)

        root_order(conn)
      end

      assert move.(c, "top") == ["C", "A", "B"]
      assert move.(c, "bottom") == ["A", "B", "C"]
      assert move.(c, "0") == ["C", "A", "B"]
      assert move.(c, "soon") == ["A", "B", "C"]
      assert move.(a, 1.5) == ["B", "C", "A"]
    end

    test "under a parent, back with none or \"\", and an unknown parent is a 404", %{
      conn: conn,
      a: a,
      b: b
    } do
      conn
      |> post("/api/pages/#{b["id"]}/move", %{parent: a["code"]})
      |> json_response(200)

      assert Wiki.get_page!(b["id"]).parent_id == a["id"]

      for parent <- ["none", ""] do
        conn |> post("/api/pages/#{b["id"]}/move", %{parent: parent}) |> json_response(200)
        assert Wiki.get_page!(b["id"]).parent_id == nil
      end

      assert %{"error" => error} =
               conn
               |> post("/api/pages/#{b["id"]}/move", %{parent: "Nobody"})
               |> json_response(404)

      assert error =~ "Nobody"
    end
  end

  describe "pins" do
    setup %{conn: conn, board: board} do
      %{
        page: create(conn, %{title: "Spec"}),
        other: create(conn, %{title: "Design"}),
        card: card_fixture(hd(board.columns), %{"title" => "Build it"})
      }
    end

    test "to another page", %{conn: conn, page: page, other: other} do
      assert %{"pinned" => true} =
               conn
               |> post("/api/pages/#{page["id"]}/links", %{page: other["code"]})
               |> json_response(200)
    end

    test "with no target, an unknown card, or a card named by words", %{
      conn: conn,
      page: page
    } do
      assert %{"error" => error} =
               conn |> post("/api/pages/#{page["id"]}/links", %{}) |> json_response(400)

      assert error =~ "card` or `page"

      assert %{"error" => "card 999999999 not found"} =
               conn
               |> post("/api/pages/#{page["id"]}/links", %{card: 999_999_999})
               |> json_response(404)

      assert %{"error" => "a card is named by its number"} =
               conn
               |> post("/api/pages/#{page["id"]}/links", %{card: "build it"})
               |> json_response(400)
    end

    test "a card the caller cannot read cannot be pinned to", %{conn: conn, page: page} do
      stranger = user_fixture("pages.stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
      hidden = card_fixture(hd(theirs.columns), %{"title" => "Hidden"})

      assert conn
             |> post("/api/pages/#{page["id"]}/links", %{card: hidden.id})
             |> json_response(403)
    end
  end

  describe "on the board" do
    test "place with no column takes the page off the board", %{conn: conn, board: board} do
      page = create(conn, %{title: "Placed"})
      column = hd(board.columns)

      assert %{"placed" => true} =
               conn
               |> post("/api/pages/#{page["id"]}/place", %{column: column.name})
               |> json_response(200)

      assert Wiki.get_page!(page["id"]).column_id == column.id

      assert %{"placed" => false} =
               conn
               |> post("/api/pages/#{page["id"]}/place", %{column: nil})
               |> json_response(200)

      assert Wiki.get_page!(page["id"]).column_id == nil
    end
  end

  describe "export and import" do
    test "export hands back each page as a file, archived ones only when asked", %{conn: conn} do
      create(conn, %{title: "Kept", body: "still here"})
      gone = create(conn, %{title: "Gone"})
      conn |> delete("/api/pages/#{gone["id"]}") |> json_response(200)

      assert %{"board" => %{"code" => "pagesapi"}, "count" => 1, "files" => [file]} =
               conn |> get("/api/boards/pagesapi/pages/export") |> json_response(200)

      assert file["path"] == "Kept.md"
      assert file["body"] =~ "still here"

      assert %{"count" => 2} =
               conn |> get("/api/boards/pagesapi/pages/export?archived=all") |> json_response(200)
    end

    test "a reader's export leaves drafts out", %{conn: conn, board: board, user: user} do
      create(conn, %{title: "Public", body: "for all"})
      create(conn, %{title: "Draft", body: "half", status: "draft"})
      reader = user_fixture("pages.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", user)

      assert %{"files" => [%{"body" => body}]} =
               conn_as(reader)
               |> put_req_header("accept", "application/json")
               |> get("/api/boards/pagesapi/pages/export")
               |> json_response(200)

      assert body =~ "for all"
    end

    test "import writes files, skips titles already there, and overwrite replaces", %{
      conn: conn
    } do
      create(conn, %{title: "Existing", body: "old"})

      files = [
        %{path: "fresh.md", body: "---\ntitle: Fresh\n---\nnew text"},
        %{path: "existing.md", body: "---\ntitle: Existing\n---\nreplaced"}
      ]

      assert %{"created" => [%{"title" => "Fresh"}], "skipped" => [%{"path" => "existing.md"}]} =
               conn
               |> post("/api/boards/pagesapi/pages/import", %{files: files})
               |> json_response(200)

      assert %{"created" => created} =
               conn
               |> post("/api/boards/pagesapi/pages/import", %{
                 files: tl(files),
                 overwrite: true
               })
               |> json_response(200)

      assert [%{"title" => "Existing"}] = created
      assert {:ok, page} = Wiki.find_page(board_of(conn), "Existing")
      assert page.body =~ "replaced"
    end

    test "import refuses no files, and a file without a path or a body", %{conn: conn} do
      for files <- [nil, [], "a.md"] do
        assert %{"error" => error} =
                 conn
                 |> post("/api/boards/pagesapi/pages/import", %{files: files})
                 |> json_response(400)

        assert error =~ "list of {path, body}"
      end

      assert %{"error" => error} =
               conn
               |> post("/api/boards/pagesapi/pages/import", %{files: [%{path: "a.md"}]})
               |> json_response(400)

      assert error =~ "each file needs a path and a body"
      assert titles(conn, "") == []
    end
  end

  defp board_of(_conn), do: Slipdock.Boards.find_board("pagesapi") |> elem(1)

  describe "the query language" do
    test "the vocabulary names the views, operators and an example", %{conn: conn} do
      assert %{"views" => views, "operators" => operators, "example" => example} =
               conn |> get("/api/pages/query-vocabulary") |> json_response(200)

      assert "table" in views
      assert Enum.any?(operators, &(&1["write"] == "field in a|b"))
      assert example =~ "```slipdock"
    end

    test "a block is checked: an answer, a parse error, or no block at all", %{
      conn: conn,
      board: board
    } do
      card_fixture(hd(board.columns), %{"title" => "Findable"})

      assert %{"ok" => true, "answer" => answer} =
               conn
               |> post("/api/pages/query", %{board: "pagesapi", query: "view: list\nboard: this"})
               |> json_response(200)

      assert inspect(answer) =~ "Findable"

      assert %{"ok" => false, "error" => error} =
               conn
               |> post("/api/pages/query", %{board: "pagesapi", body: "view: sideways"})
               |> json_response(200)

      assert error =~ "view must be one of"

      assert conn |> post("/api/pages/query", %{board: "pagesapi"}) |> json_response(400)
      assert conn |> post("/api/pages/query", %{query: "view: list"}) |> json_response(404)
    end
  end

  describe "templates" do
    test "no template named is a 400, an unknown one a 404", %{conn: conn} do
      assert %{"error" => "name the `template` to use"} =
               conn
               |> post("/api/boards/pagesapi/pages/from-template", %{})
               |> json_response(400)

      assert %{"error" => error} =
               conn
               |> post("/api/boards/pagesapi/pages/from-template", %{template: "Nope"})
               |> json_response(404)

      assert error =~ "template"
    end

    test "an empty card is no card, an unknown one a 404", %{conn: conn} do
      create(conn, %{title: "Decision", body: "# {{title}}", template: true})

      assert %{"page" => %{"title" => "Chosen"}} =
               conn
               |> post("/api/boards/pagesapi/pages/from-template", %{
                 template: "Decision",
                 title: "Chosen",
                 card: ""
               })
               |> json_response(201)

      assert conn
             |> post("/api/boards/pagesapi/pages/from-template", %{
               template: "Decision",
               card: 999_999_999
             })
             |> json_response(404)
    end
  end

  describe "history" do
    setup %{conn: conn} do
      %{page: create(conn, %{title: "Doc", body: "first"})}
    end

    test "a revision without a diff is just the revision; an unknown one a 404", %{
      conn: conn,
      page: page
    } do
      assert %{"revisions" => [rev]} =
               conn |> get("/api/pages/#{page["id"]}/revisions?limit=junk") |> json_response(200)

      assert %{"revision" => %{"body" => "first"}} =
               body =
               conn
               |> get("/api/pages/#{page["id"]}/revisions/#{rev["id"]}")
               |> json_response(200)

      refute Map.has_key?(body, "diff")

      # The first revision is all insertion: no phantom blank line deleted.
      assert %{"diff" => [%{"op" => "ins", "lines" => ["first"]}]} =
               conn
               |> get("/api/pages/#{page["id"]}/revisions/#{rev["id"]}?diff=previous")
               |> json_response(200)

      assert %{"error" => "revision not found"} =
               conn |> get("/api/pages/#{page["id"]}/revisions/999999999") |> json_response(404)

      assert %{"error" => "revision not found"} =
               conn
               |> post("/api/pages/#{page["id"]}/revert", %{revision_id: 999_999_999})
               |> json_response(404)
    end

    test "limit caps the list, and a zero or nonsense limit means the default", %{
      conn: conn,
      page: page,
      board: board
    } do
      other = user_fixture("pages.second@example.com")
      {:ok, _} = Slipdock.Access.grant(board, other, "write", user_fixture())

      conn_as(other)
      |> put_req_header("accept", "application/json")
      |> patch("/api/pages/#{page["id"]}", %{body: "second"})
      |> json_response(200)

      count = fn limit ->
        conn
        |> get("/api/pages/#{page["id"]}/revisions?limit=#{limit}")
        |> json_response(200)
        |> Map.fetch!("revisions")
        |> length()
      end

      assert count.("1") == 1
      assert count.("0") == 2
      assert count.("") == 2
    end
  end

  describe "folders by id" do
    setup %{conn: conn} do
      %{"folder" => folder} =
        conn |> post("/api/boards/pagesapi/folders", %{name: "Design"}) |> json_response(201)

      %{folder: folder}
    end

    test "renamed by id, and an unknown parent or id is a 404", %{conn: conn, folder: folder} do
      assert %{"folder" => %{"name" => "Designs"}} =
               conn
               |> patch("/api/folders/#{folder["id"]}", %{name: "Designs"})
               |> json_response(200)

      assert conn
             |> patch("/api/folders/#{folder["id"]}", %{parent: "Nowhere"})
             |> json_response(404)

      for id <- ["999999999", "design"] do
        assert %{"error" => error} =
                 conn |> patch("/api/folders/#{id}", %{name: "X"}) |> json_response(404)

        assert error =~ "folder"
      end
    end

    test "somebody who cannot write the board cannot rename it", %{
      folder: folder,
      board: board,
      user: user
    } do
      reader = user_fixture("folders.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", user)

      assert conn_as(reader)
             |> put_req_header("accept", "application/json")
             |> patch("/api/folders/#{folder["id"]}", %{name: "Mine"})
             |> json_response(403)

      assert {:ok, %{name: "Design"}} = Wiki.find_folder(board, folder["id"])
    end
  end

  describe "the card contents a page carries" do
    setup %{conn: conn} do
      %{page: create(conn, %{title: "Carrier"})}
    end

    test "votes: missing, not a number, or over the cap is a 422", %{conn: conn, page: page} do
      assert %{"error" => "count is required"} =
               conn |> post("/api/pages/#{page["id"]}/vote", %{}) |> json_response(422)

      assert %{"error" => "count must be a whole number"} =
               conn |> post("/api/pages/#{page["id"]}/vote", %{count: "x"}) |> json_response(422)

      assert %{"error" => error} =
               conn |> post("/api/pages/#{page["id"]}/vote", %{count: 99}) |> json_response(422)

      assert error =~ "At most"

      assert %{"my_votes" => 2} =
               conn |> post("/api/pages/#{page["id"]}/vote", %{count: "2"}) |> json_response(200)
    end

    test "a reader cannot remove a page's link", %{page: page, board: board, user: user} do
      {:ok, url} =
        Slipdock.Boards.add_card_url(Wiki.get_page!(page["id"]), %{"url" => "https://x.y"})

      reader = user_fixture("pages.urlreader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", user)

      assert conn_as(reader)
             |> put_req_header("accept", "application/json")
             |> delete("/api/pages/#{page["id"]}/urls/#{url.id}")
             |> json_response(403)

      assert Slipdock.Repo.get(Slipdock.Boards.CardUrl, url.id)
    end
  end
end

defmodule SlipdockWeb.API.PageControllerLimitTest do
  @moduledoc """
  The 402s a page endpoint answers when the owner's account is full: pages
  are items, and so are the cards a page makes.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Settings, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Full wiki", "code" => "fullwiki"}, owner: user)
    page = page_fixture(board, %{"title" => "Archived", "body" => "a passage"})
    {:ok, page} = Wiki.archive_page(page)
    live = page_fixture(board, %{"title" => "Live", "body" => "a passage"})

    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      page: page,
      live: live
    }
  end

  test "restoring an archived page past the limit is a 402 and it stays archived", %{
    conn: conn,
    page: page
  } do
    body = conn |> post("/api/pages/#{page.id}/restore") |> json_response(402)

    assert body["error"] == "card_limit_reached"
    assert body["retryable"] == false
    assert Wiki.get_page!(page.id).archived_at
  end

  test "turning a passage into a card past the limit is a 402 and no card is made", %{
    conn: conn,
    board: board,
    live: live
  } do
    body =
      conn |> post("/api/pages/#{live.id}/cards", %{text: "Do the thing"}) |> json_response(402)

    assert body["error"] == "card_limit_reached"
    assert Boards.list_cards(board) == []
  end
end
