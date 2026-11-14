defmodule SlipdockWeb.API.PageBodyFrontMatterTest do
  @moduledoc """
  A body sent as a whole note (#2992): over the API and MCP a `---` front
  matter block at its top is stored as the page's front matter, as a vault
  sync stores a file's, and the rest is the body. A horizontal rule is not a
  block, a block sent beside a `front_matter` of its own is refused, and an
  append, a section write and the editor's own saves are left as they were.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki
  alias Slipdock.Wiki.Excalidraw

  @drawing "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n\n==Switch to EXCALIDRAW VIEW==\n\n# Excalidraw Data\n"
  @header "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n\n"
  @rest "==Switch to EXCALIDRAW VIEW==\n\n# Excalidraw Data\n"

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Notes", "code" => "fmbody"}, owner: user)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board}
  end

  defp stored(%{"id" => id}), do: Wiki.get_page!(id)
  defp stored(id), do: Wiki.get_page!(id)

  defp post_page(conn, path, params),
    do: conn |> post(path, params) |> json_response(201) |> Map.fetch!("page")

  describe "POST" do
    test "a drawing's note becomes a drawing: the block is front matter, the rest the body",
         %{conn: conn} do
      json =
        post_page(conn, "/api/boards/fmbody/pages", %{"title" => "Sketch", "body" => @drawing})

      assert json["front_matter"] == "excalidraw-plugin: parsed\ntags: [excalidraw]"
      assert json["body"] == @rest

      page = stored(json)
      assert page.front_matter == @header
      assert page.body == @rest
      assert Excalidraw.page?(page)
      # The file it came from is the two put back together.
      assert page.front_matter <> page.body == @drawing
      # The first revision holds the body as stored, not as sent.
      assert hd(Wiki.list_revisions(page)).body == @rest
    end

    test "a body that opens with a horizontal rule stays body", %{conn: conn} do
      for body <- ["---\n\nAfter the rule.\n", "---\njust prose\n---\nmore\n", "---\n---\n"] do
        page =
          conn
          |> post_page("/api/boards/fmbody/pages", %{"title" => "Rule #{body}", "body" => body})
          |> stored()

        assert page.front_matter == nil
        assert page.body == body
      end
    end

    test "a block in the body and front_matter together are refused, and nothing is made",
         %{conn: conn, board: board} do
      assert %{"error" => error} =
               conn
               |> post("/api/boards/fmbody/pages", %{
                 "title" => "Both",
                 "body" => "---\na: 1\n---\nText",
                 "front_matter" => "b: 2"
               })
               |> json_response(422)

      assert error =~ "front_matter"
      assert error =~ "send one"
      assert Wiki.list_pages(board) == []
    end

    test "a page for a card, a write-up and a page in a folder split it too",
         %{conn: conn, board: board} do
      card = card_fixture(hd(board.columns), %{"title" => "Draw it"})
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Drawings"})

      for {path, params} <- [
            {"/api/boards/fmbody/pages", %{"card" => card.id}},
            {"/api/cards/#{card.id}/pages", %{}},
            {"/api/folders/#{folder.id}/pages", %{}}
          ] do
        page =
          conn
          |> post_page(path, Map.merge(params, %{"title" => "At #{path}", "body" => @drawing}))
          |> stored()

        assert page.front_matter == @header, path
        assert page.body == @rest, path
      end
    end

    test "a page for a card, a write-up and a page in a folder refuse a block and front_matter together",
         %{conn: conn, board: board} do
      card = card_fixture(hd(board.columns), %{"title" => "Draw it"})
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Drawings"})

      for {path, params} <- [
            {"/api/boards/fmbody/pages", %{"card" => card.id}},
            {"/api/cards/#{card.id}/pages", %{}},
            {"/api/folders/#{folder.id}/pages", %{}}
          ],
          front_matter <- ["b: 2", ""] do
        assert %{"error" => error} =
                 conn
                 |> post(
                   path,
                   Map.merge(params, %{
                     "title" => "Both at #{path}",
                     "body" => "---\na: 1\n---\nx",
                     "front_matter" => front_matter
                   })
                 )
                 |> json_response(422),
               path

        assert error =~ "send one", path
      end

      assert Wiki.list_pages(board) == []

      # A body with no block beside the field is written as it always was.
      page =
        conn
        |> post_page("/api/folders/#{folder.id}/pages", %{
          "title" => "Plain",
          "body" => "Just text",
          "front_matter" => "b: 2"
        })
        |> stored()

      assert page.body == "Just text"
    end
  end

  describe "PATCH" do
    setup %{board: board, user: user} do
      {:ok, page} =
        Wiki.create_page(
          board,
          %{"title" => "Note", "body" => "Old", "front_matter" => "---\nrating: 5\n---\n"},
          user: user
        )

      %{page: page}
    end

    test "a block in the new body replaces the page's front matter", %{conn: conn, page: page} do
      json =
        conn
        |> patch("/api/pages/#{page.code}", %{"body" => @drawing})
        |> json_response(200)
        |> Map.fetch!("page")

      assert json["front_matter"] == "excalidraw-plugin: parsed\ntags: [excalidraw]"
      assert stored(page.id).front_matter == @header
      assert stored(page.id).body == @rest
    end

    test "a body with no block leaves the front matter alone", %{conn: conn, page: page} do
      conn |> patch("/api/pages/#{page.code}", %{"body" => "New text"}) |> json_response(200)

      assert stored(page.id).front_matter == "---\nrating: 5\n---\n"
      assert stored(page.id).body == "New text"
    end

    test "a block and front_matter together are refused, and the page is as it was",
         %{conn: conn, page: page} do
      for front_matter <- ["b: 2", ""] do
        assert %{"error" => error} =
                 conn
                 |> patch("/api/pages/#{page.code}", %{
                   "body" => "---\na: 1\n---\nText",
                   "front_matter" => front_matter
                 })
                 |> json_response(422)

        assert error =~ "send one"
      end

      assert stored(page.id).front_matter == "---\nrating: 5\n---\n"
      assert stored(page.id).body == "Old"
    end

    test "an append and a section write never move text into the front matter",
         %{conn: conn, board: board, user: user} do
      # A page whose body already opens with a block, as the editor may save.
      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Kept", "body" => "---\na: 1\n---\n\n## Log\n"},
          user: user
        )

      assert page.front_matter == nil

      conn |> post("/api/pages/#{page.code}/append", %{"body" => "more"}) |> json_response(200)

      conn
      |> post("/api/pages/#{page.code}/section/Log", %{"body" => "- entry"})
      |> json_response(200)

      page = stored(page.id)
      assert page.front_matter == nil
      assert String.starts_with?(page.body, "---\na: 1\n---\n")
      assert page.body =~ "more"
      assert page.body =~ "- entry"
    end
  end

  describe "the context" do
    test "splits only when asked, so the editor's saves are untouched",
         %{board: board, user: user} do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Typed", "body" => @drawing}, user: user)
      assert page.front_matter == nil
      assert page.body == @drawing

      {:ok, page} = Wiki.update_page(page, %{"body" => "---\nk: v\n---\nx"}, user: user)
      assert page.front_matter == nil
      assert page.body == "---\nk: v\n---\nx"

      {:ok, page} =
        Wiki.update_page(page, %{"body" => "---\nk: v\n---\nx"},
          user: user,
          split_front_matter: true
        )

      assert page.front_matter == "---\nk: v\n---\n"
      assert page.body == "x"
    end
  end

  describe "over MCP" do
    defp call(conn, args) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "write_page", arguments: args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    test "create and replace split the block; append does not", %{conn: conn, board: board} do
      made =
        call(conn, %{mode: "create", board: "fmbody", title: "Sketch", body: @drawing})[
          "structuredContent"
        ]

      page = stored(made["id"])
      assert page.front_matter == @header
      assert page.body == @rest
      assert Excalidraw.page?(page)

      replaced =
        call(conn, %{
          mode: "replace",
          page: made["code"],
          base_hash: made["content_hash"],
          body: "---\nrating: 3\n---\nRewritten"
        })

      assert replaced["isError"] == false, inspect(replaced["content"])
      assert stored(made["id"]).front_matter == "---\nrating: 3\n---\n"
      assert stored(made["id"]).body == "Rewritten"

      appended = call(conn, %{mode: "append", page: made["code"], body: "---\nz: 1\n---\n"})
      assert appended["isError"] == false, inspect(appended["content"])
      assert stored(made["id"]).front_matter == "---\nrating: 3\n---\n"
      assert stored(made["id"]).body =~ "z: 1"

      card = card_fixture(hd(board.columns), %{"title" => "Draw it"})

      for_card =
        call(conn, %{mode: "create", card: card.id, title: "For the card", body: @drawing})[
          "structuredContent"
        ]

      assert stored(for_card["id"]).front_matter == @header
    end
  end
end
