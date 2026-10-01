defmodule SlipdockWeb.API.SearchTest do
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Search}

  setup %{user: user} do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()

    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Invoice rounding is wrong on refunds"})
    {:ok, _} = Boards.add_comment(card, "the staging rollback was blocked on approvals")
    {:ok, _} = Search.index_cards(Search.load_cards(Search.all_card_ids()))

    %{board: board, card: card}
  end

  describe "GET /api/search" do
    test "returns matching cards with the chunks that matched", ctx do
      body =
        ctx.conn
        |> get(~p"/api/search", %{"q" => "invoice rounding refunds"})
        |> json_response(200)

      assert body["query"] == "invoice rounding refunds"
      assert body["count"] == 1

      assert [%{"card" => card, "score" => score, "matches" => matches}] = body["results"]
      assert card["id"] == ctx.card.id
      assert card["board"]["code"] == "delivery"
      assert card["url"] == "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
      assert is_float(score) and score > 0.0
      assert Enum.any?(matches, &(&1["kind"] == "card"))
    end

    test "a comment match is reported as one", ctx do
      body =
        ctx.conn
        |> get(~p"/api/search", %{"q" => "staging rollback blocked approvals"})
        |> json_response(200)

      assert [%{"matches" => matches}] = body["results"]
      comment = Enum.find(matches, &(&1["kind"] == "comment"))
      assert comment["text"] =~ "staging rollback was blocked"
    end

    test "q is required", %{conn: conn} do
      assert %{"error" => "q is required"} =
               conn |> get(~p"/api/search") |> json_response(400)
    end

    test "limit is capped and validated", ctx do
      assert %{"error" => "limit must be a positive number"} =
               ctx.conn
               |> get(~p"/api/search", %{"q" => "invoice", "limit" => "lots"})
               |> json_response(400)

      assert %{"results" => results} =
               ctx.conn
               |> get(~p"/api/search", %{"q" => "invoice", "limit" => "1"})
               |> json_response(200)

      assert length(results) <= 1
    end

    test "a board can be named by code, name or id", ctx do
      for reference <- ["delivery", "Delivery", to_string(ctx.board.id)] do
        assert %{"count" => 1} =
                 ctx.conn
                 |> get(~p"/api/search", %{"q" => "invoice rounding", "board" => reference})
                 |> json_response(200)
      end

      assert %{"error" => error} =
               ctx.conn
               |> get(~p"/api/search", %{"q" => "invoice", "board" => "nowhere"})
               |> json_response(400)

      assert error =~ "no board you can see"
    end

    test "archived cards need asking for", ctx do
      {:ok, _} = Boards.archive_card(ctx.card)
      {:ok, _} = Search.index_card(ctx.card.id)

      assert %{"count" => 0} =
               ctx.conn
               |> get(~p"/api/search", %{"q" => "invoice rounding"})
               |> json_response(200)

      assert %{"count" => 1, "results" => [%{"card" => %{"archived" => true}}]} =
               ctx.conn
               |> get(~p"/api/search", %{"q" => "invoice rounding", "archived" => "true"})
               |> json_response(200)
    end

    test "another user's boards are not searchable", ctx do
      stranger = user_fixture("stranger@example.com")

      assert %{"count" => 0} =
               conn_as(stranger)
               |> get(~p"/api/search", %{"q" => "invoice rounding refunds"})
               |> json_response(200)

      {:ok, _} = Access.grant(ctx.board, stranger, "read", ctx.user)

      assert %{"count" => 1} =
               conn_as(stranger)
               |> get(~p"/api/search", %{"q" => "invoice rounding refunds"})
               |> json_response(200)
    end

    @tag :anonymous
    test "the endpoint needs a token", %{conn: conn} do
      assert conn |> get(~p"/api/search", %{"q" => "anything"}) |> json_response(401)
    end
  end

  describe "POST /api/ask" do
    test "answers, naming what it searched and what it read", ctx do
      Slipdock.AIStub.reply_sequence([
        {:tool_calls, [{"search_cards", %{"query" => "invoice rounding"}}]},
        "Finance are waiting on the refund rounding card."
      ])

      body =
        ctx.conn
        |> post(~p"/api/ask", %{"q" => "What's happening with refunds?"})
        |> json_response(200)

      assert body["answer"] =~ "Finance are waiting"
      assert body["searches"] == ["invoice rounding"]
      assert [source] = body["sources"]
      assert source["id"] == ctx.card.id
      assert source["board"] == "Delivery"
      assert source["found_by"] == "invoice rounding"
      assert source["url"] == "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
    end

    test "a conversation can be carried over", ctx do
      Slipdock.AIStub.reply_with("Still the same one.")

      assert %{"answer" => "Still the same one."} =
               ctx.conn
               |> post(~p"/api/ask", %{
                 "q" => "and what about now?",
                 "history" => [
                   %{"role" => "user", "content" => "what about refunds"},
                   %{"role" => "assistant", "content" => "the rounding card"}
                 ]
               })
               |> json_response(200)

      assert_receive {:ai_request, %{"messages" => messages}}
      assert Enum.any?(messages, &(&1["content"] == "the rounding card"))
    end

    test "q is required", %{conn: conn} do
      assert %{"error" => "q is required"} = conn |> post(~p"/api/ask", %{}) |> json_response(400)
    end

    test "a model failure comes back as an error", ctx do
      Slipdock.AIStub.fail_with(429, "slow down")

      assert %{"error" => error} =
               ctx.conn |> post(~p"/api/ask", %{"q" => "anything"}) |> json_response(400)

      assert error =~ "rate-limited"
    end
  end

  describe "saved queries" do
    test "saves, lists and removes, scoped to the token's owner", ctx do
      assert %{"saved" => []} = ctx.conn |> get(~p"/api/saved-queries") |> json_response(200)

      assert %{"saved" => [saved]} =
               ctx.conn
               |> post(~p"/api/saved-queries", %{"mode" => "search", "q" => "flaky tests"})
               |> json_response(200)

      assert saved["mode"] == "search"
      assert saved["text"] == "flaky tests"

      # Listing narrows by mode.
      assert %{"saved" => [_]} =
               ctx.conn
               |> get(~p"/api/saved-queries", %{"mode" => "search"})
               |> json_response(200)

      assert %{"saved" => []} =
               ctx.conn |> get(~p"/api/saved-queries", %{"mode" => "ask"}) |> json_response(200)

      # Nobody else can see it.
      assert %{"saved" => []} =
               conn_as(user_fixture("stranger@example.com"))
               |> get(~p"/api/saved-queries")
               |> json_response(200)

      assert %{"saved" => []} =
               ctx.conn |> delete(~p"/api/saved-queries/#{saved["id"]}") |> json_response(200)
    end

    test "saving the same thing twice is saving it once", ctx do
      body = %{"mode" => "ask", "q" => "what is at risk"}

      assert %{"saved" => [_]} =
               ctx.conn |> post(~p"/api/saved-queries", body) |> json_response(200)

      assert %{"saved" => [_]} =
               ctx.conn |> post(~p"/api/saved-queries", body) |> json_response(200)
    end

    test "removing by text, and removing what was never there", ctx do
      {:ok, _} = Slipdock.SavedQueries.save(ctx.user, "ask", "by text")

      assert %{"saved" => []} =
               ctx.conn
               |> delete(~p"/api/saved-queries", %{"mode" => "ask", "q" => "by text"})
               |> json_response(200)

      assert %{"saved" => []} =
               ctx.conn
               |> delete(~p"/api/saved-queries", %{"mode" => "ask", "q" => "never was"})
               |> json_response(200)
    end

    test "mode and text are validated", ctx do
      assert %{"error" => "q is required"} =
               ctx.conn |> post(~p"/api/saved-queries", %{"mode" => "ask"}) |> json_response(400)

      assert %{"error" => error} =
               ctx.conn
               |> post(~p"/api/saved-queries", %{"q" => "hello", "mode" => "shout"})
               |> json_response(400)

      assert error =~ "mode must be one of"

      assert %{"error" => error} =
               ctx.conn |> post(~p"/api/saved-queries", %{"q" => "hello"}) |> json_response(400)

      assert error =~ "mode must be one of"
    end

    test "another user's saved query is not yours to delete", ctx do
      stranger = user_fixture("stranger@example.com")
      {:ok, theirs} = Slipdock.SavedQueries.save(stranger, "search", "theirs")

      assert %{"saved" => []} =
               ctx.conn |> delete(~p"/api/saved-queries/#{theirs.id}") |> json_response(200)

      assert [%{text: "theirs"}] = Slipdock.SavedQueries.list(stranger, "search")
    end
  end

  describe "GET /api/search/status" do
    test "says what is indexed", ctx do
      body = ctx.conn |> get(~p"/api/search/status") |> json_response(200)

      assert body["available"] == true
      assert body["chunks"] == 2
      assert body["cards"] == 1
      assert body["model"] == "openai/text-embedding-3-small"
    end
  end
end
