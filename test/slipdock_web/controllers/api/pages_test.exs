defmodule SlipdockWeb.API.PagesTest do
  @moduledoc """
  The wiki over HTTP. The premise is that anything a person can do to a page
  a token can do too, so these cover the whole phase-one surface — and, more
  importantly, the parts an agent gets wrong: the conflict, the provenance
  recorded on every write, and drafts staying out of a reader's sight.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "API Wiki", "code" => "apiwiki"}, owner: user)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board}
  end

  defp create(conn, body) do
    conn |> post("/api/boards/apiwiki/pages", body) |> json_response(201)
  end

  describe "listing and creating" do
    test "creates a page and hands back its code, slug and hash", %{conn: conn} do
      assert %{"page" => page} =
               create(conn, %{title: "Retry policy", body: "# Retry\n\nThree times."})

      assert page["slug"] == "retry-policy"
      assert page["code"] =~ ~r/^W-\d+$/
      assert page["body"] == "# Retry\n\nThree times."
      assert page["content_hash"]
      assert page["url"] =~ "/wiki/retry-policy"
    end

    test "lists flat and as a tree", %{conn: conn} do
      %{"page" => parent} = create(conn, %{title: "Deploys"})
      create(conn, %{title: "Rollback", parent: parent["code"]})

      assert %{"pages" => flat} =
               conn |> get("/api/boards/apiwiki/pages") |> json_response(200)

      assert length(flat) == 2
      refute Map.has_key?(hd(flat), "body")

      assert %{"pages" => [top]} =
               conn |> get("/api/boards/apiwiki/pages?tree=true") |> json_response(200)

      assert top["title"] == "Deploys"
      assert [%{"title" => "Rollback"}] = top["children"]
    end

    test "filters by text and by parent", %{conn: conn} do
      create(conn, %{title: "Deploys", body: "how we ship"})
      create(conn, %{title: "Refunds", body: "money back"})

      assert %{"pages" => [found]} =
               conn |> get("/api/boards/apiwiki/pages?q=money") |> json_response(200)

      assert found["title"] == "Refunds"

      assert %{"pages" => []} =
               conn
               |> get("/api/boards/apiwiki/pages?parent=root&q=nothing")
               |> json_response(200)
    end
  end

  describe "reading and writing one page" do
    setup %{conn: conn} do
      %{"page" => page} = create(conn, %{title: "Runbook", body: "one"})
      %{page: page}
    end

    # `board-code/slug` is one path segment, so the slash in it is encoded —
    # which is what `SlipdockCLI.HTTP.seg/1` does for every reference it sends.
    test "is reachable by id, code and board/slug", %{conn: conn, page: page} do
      for ref <- [page["id"], page["code"], "apiwiki%2Frunbook"] do
        assert %{"page" => found} = conn |> get("/api/pages/#{ref}") |> json_response(200)
        assert found["id"] == page["id"]
      end
    end

    test "a matching base_hash saves, a stale one is a 409 with both sides", %{
      conn: conn,
      page: page
    } do
      assert %{"page" => saved} =
               conn
               |> patch("/api/pages/#{page["code"]}", %{
                 body: "two",
                 base_hash: page["content_hash"],
                 message: "second thoughts"
               })
               |> json_response(200)

      assert saved["body"] == "two"

      assert %{"error" => error, "current" => current} =
               conn
               |> patch("/api/pages/#{page["code"]}", %{
                 body: "three",
                 base_hash: page["content_hash"]
               })
               |> json_response(409)

      assert error =~ "conflict"
      assert current["body"] == "two"
      assert current["content_hash"] == saved["content_hash"]
    end

    test "records who wrote it: via the API, under the token's name", %{
      conn: conn,
      page: page,
      user: user
    } do
      conn |> patch("/api/pages/#{page["id"]}", %{body: "changed", message: "why"})

      {:ok, found} = Wiki.find_page(page["id"])
      assert [revision | _] = Wiki.list_revisions(found)
      assert revision.via == "api"
      assert revision.agent == "test"
      assert revision.summary == "why"
      assert revision.author_id == user.id
    end

    test "a client may name itself, and the CLI does", %{conn: conn, page: page} do
      conn
      |> put_req_header("x-kanban-client", "cli")
      |> patch("/api/pages/#{page["id"]}", %{body: "from a shell"})

      {:ok, found} = Wiki.find_page(page["id"])
      assert [%{via: "cli"} | _] = Wiki.list_revisions(found)
    end

    test "moves under a parent", %{conn: conn, page: page} do
      %{"page" => parent} = create(conn, %{title: "Parent"})

      assert %{"page" => moved} =
               conn
               |> post("/api/pages/#{page["id"]}/move", %{parent: parent["code"]})
               |> json_response(200)

      assert moved["parent_id"] == parent["id"]
    end

    test "archives, restores, and purges only for the owner", %{conn: conn, page: page} do
      assert %{"page" => archived} =
               conn |> delete("/api/pages/#{page["id"]}") |> json_response(200)

      assert archived["archived_at"]

      assert %{"page" => restored} =
               conn |> post("/api/pages/#{page["id"]}/restore") |> json_response(200)

      refute restored["archived_at"]

      assert %{"deleted" => true} =
               conn |> delete("/api/pages/#{page["id"]}?purge=true") |> json_response(200)

      assert conn |> get("/api/pages/#{page["id"]}") |> json_response(404)
    end
  end

  describe "the card facets" do
    test "a page takes them, reports them, and adjusts its flags", %{conn: conn, user: user} do
      %{"page" => page} = create(conn, %{title: "The spec"})

      assert page["priority"] == "none"
      assert page["flags"] == []

      assert %{"page" => set} =
               conn
               |> patch("/api/pages/#{page["id"]}", %{
                 priority: "critical",
                 flags: ["blocked"],
                 due_date: "2026-10-09",
                 percent_complete: 40,
                 color: "amber",
                 assignee: user.email
               })
               |> json_response(200)

      assert set["priority"] == "critical"
      assert set["flags"] == ["blocked"]
      assert set["due_date"] == "2026-10-09"
      assert set["percent_complete"] == 40
      assert set["color"] == "amber"
      assert set["assignee"]["email"] == user.email

      # add/remove adjust rather than replace, as on a card.
      assert %{"page" => adjusted} =
               conn
               |> patch("/api/pages/#{page["id"]}", %{add_flags: ["review"]})
               |> json_response(200)

      assert Enum.sort(adjusted["flags"]) == ["blocked", "review"]

      assert %{"page" => adjusted} =
               conn
               |> patch("/api/pages/#{page["id"]}", %{remove_flags: ["blocked"]})
               |> json_response(200)

      assert adjusted["flags"] == ["review"]
    end

    test "a facet outside the card's vocabulary is refused", %{conn: conn} do
      %{"page" => page} = create(conn, %{title: "The spec"})

      assert %{"error" => "validation failed", "details" => details} =
               conn
               |> patch("/api/pages/#{page["id"]}", %{priority: "urgent"})
               |> json_response(422)

      assert details["priority"]
    end
  end

  describe "on the board" do
    test "a page goes into a list, moves between lists, and comes off again", %{
      conn: conn,
      board: board
    } do
      [todo, doing | _] = board.columns
      card = card_fixture(todo, %{"title" => "The work"})
      %{"page" => page} = create(conn, %{title: "The spec"})

      refute page["column_id"]

      assert %{"placed" => true, "column" => %{"name" => name}, "page" => placed} =
               conn
               |> post("/api/pages/#{page["id"]}/place", %{column: todo.name, before: card.id})
               |> json_response(200)

      assert name == todo.name
      assert placed["column_id"] == todo.id
      # Before the card, in one order with it.
      assert Slipdock.Boards.active_items(todo.id) == [page: page["id"], card: card.id]

      assert %{"page" => moved} =
               conn
               |> post("/api/pages/#{page["id"]}/place", %{column: doing.id})
               |> json_response(200)

      assert moved["column_id"] == doing.id

      assert %{"placed" => false, "page" => off} =
               conn |> delete("/api/pages/#{page["id"]}/place") |> json_response(200)

      refute off["column_id"]
    end

    test "a list on another board is refused", %{conn: conn, user: user} do
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: user)
      %{"page" => page} = create(conn, %{title: "The spec"})

      assert %{"error" => error} =
               conn
               |> post("/api/pages/#{page["id"]}/place", %{column: hd(elsewhere.columns).id})
               |> json_response(404)

      assert error =~ "list"
    end

    test "a reader cannot put a page on the board", %{conn: conn, board: board, user: user} do
      %{"page" => page} = create(conn, %{title: "The spec"})
      reader = user_fixture("api.placement.reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      assert conn_as(reader)
             |> put_req_header("accept", "application/json")
             |> post("/api/pages/#{page["id"]}/place", %{column: hd(board.columns).id})
             |> json_response(403)
    end
  end

  describe "publishing" do
    test "a page says whether it is published, and where", %{conn: conn} do
      %{"page" => page} = create(conn, %{title: "Status", body: "words"})
      refute page["published"]
      refute page["public_url"]

      assert %{"published" => true, "url" => url, "page" => published} =
               conn |> post("/api/pages/#{page["id"]}/publish", %{}) |> json_response(200)

      assert published["published"]
      assert published["public_url"] == url
      assert published["published_at"]

      assert %{"page" => withdrawn} =
               conn
               |> post("/api/pages/#{page["id"]}/publish", %{published: false})
               |> json_response(200)

      refute withdrawn["published"]
      refute withdrawn["public_url"]
    end
  end

  describe "history" do
    test "lists revisions, diffs one against the last, and reverts", %{conn: conn, user: user} do
      %{"page" => page} = create(conn, %{title: "Doc", body: "first"})

      # A second writer, so the two saves do not collapse into one revision.
      other = user_fixture("api.other@example.com")

      {:ok, _} =
        Access.grant(Slipdock.Boards.find_board("apiwiki") |> elem(1), other, "write", user)

      conn_as(other)
      |> put_req_header("accept", "application/json")
      |> patch("/api/pages/#{page["id"]}", %{body: "second"})

      assert %{"revisions" => [newest, oldest]} =
               conn |> get("/api/pages/#{page["id"]}/revisions") |> json_response(200)

      assert oldest["title"] == "Doc"

      assert %{"revision" => revision, "diff" => diff} =
               conn
               |> get("/api/pages/#{page["id"]}/revisions/#{newest["id"]}?diff=previous")
               |> json_response(200)

      assert revision["body"] == "second"
      assert %{"op" => "del", "lines" => ["first"]} in diff
      assert %{"op" => "ins", "lines" => ["second"]} in diff

      assert %{"page" => reverted} =
               conn
               |> post("/api/pages/#{page["id"]}/revert", %{revision_id: oldest["id"]})
               |> json_response(200)

      assert reverted["body"] == "first"
    end
  end

  describe "permissions" do
    setup %{board: board, user: user} do
      reader = user_fixture("api.reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      %{reader: put_req_header(conn_as(reader), "accept", "application/json")}
    end

    test "a reader may read but not write", %{conn: conn, reader: reader} do
      %{"page" => page} = create(conn, %{title: "Readable"})

      assert %{"page" => _} = reader |> get("/api/pages/#{page["id"]}") |> json_response(200)

      assert %{"error" => error} =
               reader |> patch("/api/pages/#{page["id"]}", %{body: "nope"}) |> json_response(403)

      assert error =~ "forbidden"
    end

    test "a draft is not found by a reader, and not listed either", %{
      conn: conn,
      reader: reader
    } do
      %{"page" => draft} = create(conn, %{title: "Half written", status: "draft"})

      assert reader |> get("/api/pages/#{draft["id"]}") |> json_response(404)

      assert %{"pages" => pages} =
               reader |> get("/api/boards/apiwiki/pages") |> json_response(200)

      assert pages == []

      assert %{"page" => _} = conn |> get("/api/pages/#{draft["id"]}") |> json_response(200)
    end

    test "a grant on the page alone reaches it without the board", %{conn: conn, user: user} do
      %{"page" => page} = create(conn, %{title: "Just this doc"})
      outsider = user_fixture("api.outsider@example.com")
      outsider_conn = put_req_header(conn_as(outsider), "accept", "application/json")

      assert outsider_conn |> get("/api/pages/#{page["id"]}") |> json_response(403)

      {:ok, found} = Wiki.find_page(page["id"])
      {:ok, _} = Access.grant(found, outsider, "read", user)

      assert %{"page" => seen} =
               outsider_conn |> get("/api/pages/#{page["id"]}") |> json_response(200)

      assert seen["title"] == "Just this doc"
      assert outsider_conn |> get("/api/boards/apiwiki/pages") |> json_response(404)
    end
  end
end
