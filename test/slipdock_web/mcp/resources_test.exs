defmodule SlipdockWeb.MCP.ResourcesTest do
  @moduledoc """
  MCP resources (W-1808) over `/mcp`: `resources/list` (My work, favourites,
  pins on favourite boards; cursor paging), `resources/templates/list`, and
  `resources/read` for each kind with the tools' access rules: anything a
  token can't read is -32002 with exactly the body of something missing.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Favourites, Wiki}
  alias SlipdockWeb.MCP.Resources

  defp rpc(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
    |> json_response(200)
  end

  defp with_token(conn, token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp read(conn, uri), do: rpc(conn, "resources/read", %{uri: uri})

  defp text!(%{"result" => %{"contents" => [%{"mimeType" => "text/markdown"} = c]}}),
    do: c["text"]

  defp uris(%{"result" => %{"resources" => resources}}), do: Enum.map(resources, & &1["uri"])

  setup %{user: user} do
    board = board_fixture(%{"name" => "Payments"}, owner: user)
    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "Fix the retry"})
    page = page_fixture(board, %{"title" => "Q4 plan", "body" => "The plan."}, user: user)
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
    their_card = card_fixture(hd(theirs.columns), %{"title" => "Secret"})
    %{board: board, card: card, page: page, theirs: theirs, their_card: their_card}
  end

  describe "templates" do
    test "lists a template for each kind, all Markdown", %{conn: conn} do
      %{"result" => %{"resourceTemplates" => templates}} =
        rpc(conn, "resources/templates/list", %{})

      assert Enum.map(templates, & &1["uriTemplate"]) == [
               "slipdock://board/{code}",
               "slipdock://card/{id}",
               "slipdock://page/{code}",
               "slipdock://view/{board}/{view}",
               "slipdock://work"
             ]

      assert Enum.all?(templates, &(&1["mimeType"] == "text/markdown"))
      assert Enum.all?(templates, &(is_binary(&1["name"]) and is_binary(&1["description"])))
    end
  end

  describe "resources/list" do
    test "with no favourites, only My work", %{conn: conn} do
      assert conn |> rpc("resources/list", %{}) |> uris() == ["slipdock://work"]
    end

    test "My work, then favourites in the order marked, then pins on favourite boards", ctx do
      {:ok, view} = Boards.create_saved_view(ctx.board, %{"name" => "Blocked", "config" => %{}})
      pinned = page_fixture(ctx.board, %{"title" => "Runbook"}, user: ctx.user)
      {:ok, _} = Wiki.pin(pinned, {:board, ctx.board})

      {:ok, _} = Favourites.add(ctx.user, :card, ctx.card.id)
      {:ok, _} = Favourites.add(ctx.user, :board, ctx.board.id)
      {:ok, _} = Favourites.add(ctx.user, :view, view.id)
      {:ok, _} = Favourites.add(ctx.user, :page, ctx.page.id)

      body = rpc(ctx.conn, "resources/list", %{})

      assert uris(body) == [
               "slipdock://work",
               "slipdock://card/#{ctx.card.id}",
               "slipdock://board/#{ctx.board.code}",
               "slipdock://view/#{ctx.board.code}/#{view.id}",
               "slipdock://page/#{ctx.page.code}",
               "slipdock://page/#{pinned.code}"
             ]

      refute Map.has_key?(body["result"], "nextCursor")

      pin = List.last(body["result"]["resources"])
      assert pin["name"] == "#{pinned.code} Runbook"
      assert pin["description"] =~ "Pinned to Payments"
      assert pin["mimeType"] == "text/markdown"
    end

    test "a page both favourited and pinned is listed once", ctx do
      {:ok, _} = Wiki.pin(ctx.page, {:board, ctx.board})
      {:ok, _} = Favourites.add(ctx.user, :board, ctx.board.id)
      {:ok, _} = Favourites.add(ctx.user, :page, ctx.page.id)

      assert ctx.conn
             |> rpc("resources/list", %{})
             |> uris()
             |> Enum.frequencies()
             |> Map.values() ==
               [1, 1, 1]
    end

    test "pins on a board that isn't a favourite are not listed", ctx do
      {:ok, _} = Wiki.pin(ctx.page, {:board, ctx.board})
      assert ctx.conn |> rpc("resources/list", %{}) |> uris() == ["slipdock://work"]
    end

    test "an archived card is not listed, but reads by its number", ctx do
      {:ok, _} = Favourites.add(ctx.user, :card, ctx.card.id)
      {:ok, _} = Boards.archive_card(ctx.card)

      assert ctx.conn |> rpc("resources/list", %{}) |> uris() == ["slipdock://work"]
      assert ctx.conn |> read("slipdock://card/#{ctx.card.id}") |> text!() =~ "Fix the retry"
    end

    test "a board-scoped token lists only what is inside its boards", ctx do
      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)
      {:ok, _} = Favourites.add(ctx.user, :board, ctx.board.id)
      {:ok, _} = Favourites.add(ctx.user, :board, other.id)
      {token, _} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [other.id])

      assert ctx.conn |> with_token(token) |> rpc("resources/list", %{}) |> uris() ==
               ["slipdock://work", "slipdock://board/#{other.code}"]
    end

    test "pages through with a cursor, in a stable order", ctx do
      for _ <- 1..4 do
        c = card_fixture(hd(ctx.board.columns))
        {:ok, _} = Favourites.add(ctx.user, :card, c.id)
      end

      context = %{user: ctx.user, token: %{scope: "write"}, base_url: ""}
      {:ok, first} = Resources.list(context, nil, 2)
      assert length(first.resources) == 2 and is_binary(first.nextCursor)
      {:ok, second} = Resources.list(context, first.nextCursor, 2)
      assert length(second.resources) == 2
      {:ok, last} = Resources.list(context, second.nextCursor, 2)
      assert length(last.resources) == 1
      refute Map.has_key?(last, :nextCursor)

      {:ok, all} = Resources.list(context, nil, 50)
      paged = first.resources ++ second.resources ++ last.resources
      assert Enum.map(paged, & &1.uri) == Enum.map(all.resources, & &1.uri)
      assert {:ok, ^second} = Resources.list(context, first.nextCursor, 2)
    end

    test "a cursor it never handed out is -32602", %{conn: conn} do
      body = rpc(conn, "resources/list", %{cursor: "nonsense"})
      assert body["error"]["code"] == -32602
      assert body["error"]["message"] =~ "cursor"
    end
  end

  describe "resources/read" do
    test "reads each kind as Markdown", ctx do
      {:ok, view} = Boards.create_saved_view(ctx.board, %{"name" => "Blocked", "config" => %{}})

      for uri <- [
            "slipdock://board/#{ctx.board.code}",
            "slipdock://card/#{ctx.card.id}",
            "slipdock://page/#{ctx.page.code}",
            "slipdock://view/#{ctx.board.code}/#{view.id}",
            "slipdock://view/#{ctx.board.code}/Blocked",
            "slipdock://work"
          ] do
        body = read(ctx.conn, uri)
        assert [%{"uri" => ^uri, "text" => text}] = body["result"]["contents"], uri
        assert is_binary(text) and text != ""
      end

      assert ctx.conn |> read("slipdock://page/#{ctx.page.code}") |> text!() =~ "The plan."
    end

    test "another user's card is -32002 with the same body as a missing one", ctx do
      theirs = read(ctx.conn, "slipdock://card/#{ctx.their_card.id}")
      missing = read(ctx.conn, "slipdock://card/999999999")

      assert theirs["error"]["code"] == -32002
      assert theirs["error"]["message"] == missing["error"]["message"]

      assert Map.delete(theirs["error"]["data"], "uri") ==
               Map.delete(missing["error"]["data"], "uri")

      refute inspect(theirs) =~ "Secret"
    end

    test "another user's board, page or view is -32002 too", ctx do
      {:ok, view} = Boards.create_saved_view(ctx.theirs, %{"name" => "Theirs", "config" => %{}})
      page = page_fixture(ctx.theirs, %{"title" => "Hidden"})

      for uri <- [
            "slipdock://board/#{ctx.theirs.code}",
            "slipdock://page/#{page.code}",
            "slipdock://view/#{ctx.theirs.code}/#{view.id}"
          ] do
        assert read(ctx.conn, uri)["error"]["code"] == -32002, uri
      end
    end

    test "URIs that name nothing are -32002", %{conn: conn} do
      for uri <- [
            "slipdock://nothing/1",
            "slipdock://card/abc",
            "slipdock://card/",
            "slipdock://board/",
            "https://example.com/card/1",
            "slipdock://view/onlyboard"
          ] do
        body = read(conn, uri)
        assert body["error"]["code"] == -32002, uri
        assert body["error"]["data"]["uri"] == uri
      end
    end

    test "a read without a uri is -32602", %{conn: conn} do
      assert rpc(conn, "resources/read", %{})["error"]["code"] == -32602
    end

    test "a board-scoped token can't read outside its boards", ctx do
      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)
      {token, _} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [other.id])
      conn = with_token(ctx.conn, token)

      for uri <- [
            "slipdock://board/#{ctx.board.code}",
            "slipdock://card/#{ctx.card.id}",
            "slipdock://page/#{ctx.page.code}"
          ] do
        assert read(conn, uri)["error"]["code"] == -32002, uri
      end

      assert read(conn, "slipdock://board/#{other.code}") |> text!() =~ "Other"
    end

    test "a read-only token reads fine", ctx do
      {token, _} = Accounts.create_api_token(ctx.user, "reader", scope: "read")
      conn = with_token(ctx.conn, token)

      assert read(conn, "slipdock://card/#{ctx.card.id}") |> text!() =~ "Fix the retry"
      assert read(conn, "slipdock://page/#{ctx.page.code}") |> text!() =~ "The plan."
    end
  end
end
