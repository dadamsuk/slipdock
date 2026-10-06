defmodule SlipdockWeb.API.CardControllerTest do
  @moduledoc """
  `SlipdockWeb.API.CardController` where agents and the CLI trip: the
  refusals. A read-only token, a token confined to other boards, a card or a
  row that is not there, a value that does not parse, and the 402 that means
  stop rather than try again — each has to come back as the answer a caller
  can act on, never a 500 and never a quiet success.

  The happy paths of the smaller endpoints (comments, links, status updates,
  checklist items) are here too, as the ground the refusals stand on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Cards API", "code" => "cardsapi"}, owner: user)
    [todo, doing | _] = board.columns
    card = card_fixture(todo, %{"title" => "First"})
    other = card_fixture(todo, %{"title" => "Second"})

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      todo: todo,
      doing: doing,
      card: card,
      other: other
    }
  end

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  describe "a card that is not there" do
    test "is a 404 by number, and by something that is not a number", %{conn: conn} do
      for id <- ["999999999", "abc"] do
        assert %{"error" => "card not found"} =
                 conn |> get("/api/cards/#{id}") |> json_response(404)

        assert %{"error" => "card not found"} =
                 conn |> patch("/api/cards/#{id}", %{title: "x"}) |> json_response(404)
      end
    end

    test "a link to one is a 404, and nothing is linked", %{conn: conn, card: card} do
      assert %{"error" => "card not found"} =
               conn
               |> post("/api/cards/#{card.id}/links", %{to: 999_999_999, kind: "relates"})
               |> json_response(404)

      assert Boards.get_card!(card.id).links_out == []
    end
  end

  describe "a read-only token" do
    test "reads a card but cannot comment, archive or delete it", %{user: user, card: card} do
      conn = with_token(user, scope: "read")

      assert %{"card" => %{"title" => "First"}} =
               conn |> get("/api/cards/#{card.id}") |> json_response(200)

      assert conn |> post("/api/cards/#{card.id}/comments", %{body: "hi"}) |> json_response(403)
      assert conn |> post("/api/cards/#{card.id}/archive") |> json_response(403)

      assert %{"error" => error} = conn |> delete("/api/cards/#{card.id}") |> json_response(403)
      assert error =~ "read-only"

      card = Boards.get_card!(card.id)
      assert card.comments == []
      assert card.archived_at == nil
    end
  end

  describe "a token confined to another board" do
    setup %{user: user} do
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: user)
      %{scoped: with_token(user, scope_boards: [elsewhere.id])}
    end

    test "cannot read or edit a card outside it, and says the scope is why", %{
      scoped: conn,
      card: card
    } do
      assert %{"error" => error} = conn |> get("/api/cards/#{card.id}") |> json_response(403)
      assert error =~ "scope"

      assert %{"error" => error} =
               conn |> patch("/api/cards/#{card.id}", %{title: "Moved"}) |> json_response(403)

      assert error =~ "scope"
      assert Boards.get_card!(card.id).title == "First"
    end

    test "cannot list or add cards on a board outside it", %{scoped: conn, board: board} do
      assert conn |> get("/api/boards/cardsapi/cards") |> json_response(403)
      assert conn |> post("/api/boards/cardsapi/cards", %{title: "Sneaky"}) |> json_response(403)
      refute Enum.any?(Boards.list_cards(board), &(&1.title == "Sneaky"))
    end
  end

  describe "editing" do
    test "tags: set by one name, added, removed, and an unknown one refused", %{
      conn: conn,
      board: board,
      card: card
    } do
      tag_fixture(board, "bug")
      tag_fixture(board, "ux")

      assert %{"card" => %{"tags" => ["bug"]}} =
               conn |> patch("/api/cards/#{card.id}", %{tags: "bug"}) |> json_response(200)

      assert %{"card" => %{"tags" => tags}} =
               conn
               |> patch("/api/cards/#{card.id}", %{add_tags: ["ux", "bug"], remove_tags: []})
               |> json_response(200)

      assert Enum.sort(tags) == ["bug", "ux"]

      assert %{"card" => %{"tags" => ["ux"]}} =
               conn
               |> patch("/api/cards/#{card.id}", %{remove_tags: ["bug"]})
               |> json_response(200)

      assert %{"error" => "tag \"nope\" not found"} =
               conn |> patch("/api/cards/#{card.id}", %{add_tags: ["nope"]}) |> json_response(404)

      assert Enum.map(Boards.get_card!(card.id).tags, & &1.name) == ["ux"]
    end

    test "flags are added and removed without restating the rest", %{conn: conn, card: card} do
      assert %{"card" => %{"flags" => flags}} =
               conn
               |> patch("/api/cards/#{card.id}", %{add_flags: ["blocked", "review"]})
               |> json_response(200)

      assert Enum.sort(flags) == ["blocked", "review"]

      assert %{"card" => %{"flags" => ["review"]}} =
               conn
               |> patch("/api/cards/#{card.id}", %{remove_flags: "blocked"})
               |> json_response(200)
    end

    test "column moves the card, and an unknown one is a 404 with nothing changed", %{
      conn: conn,
      card: card,
      doing: doing
    } do
      assert %{"card" => %{"column_id" => column_id}} =
               conn
               |> patch("/api/cards/#{card.id}", %{column: doing.name})
               |> json_response(200)

      assert column_id == doing.id

      # The same list again is not a move.
      assert conn |> patch("/api/cards/#{card.id}", %{column: doing.name}) |> json_response(200)

      assert %{"error" => error} =
               conn
               |> patch("/api/cards/#{card.id}", %{column: "Nowhere"})
               |> json_response(404)

      assert error =~ "Nowhere"
      assert Boards.get_card!(card.id).column_id == doing.id
    end

    test "fields: an unknown field is a 404 and a non-object is a 422", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, _} = Slipdock.Fields.create_field(board, %{"name" => "Effort", "kind" => "number"})

      assert %{"error" => "field size not found"} =
               conn
               |> patch("/api/cards/#{card.id}", %{fields: %{"size" => 3}})
               |> json_response(404)

      assert %{"error" => "fields must be an object"} =
               conn
               |> patch("/api/cards/#{card.id}", %{fields: "effort=3"})
               |> json_response(422)

      assert %{"error" => _} =
               conn
               |> patch("/api/cards/#{card.id}", %{fields: %{"effort" => "lots"}})
               |> json_response(422)
    end

    test "remove_assignees names only people already on the card", %{conn: conn, card: card} do
      assert %{"card" => %{"assignees" => [_]}} =
               conn |> patch("/api/cards/#{card.id}", %{assignee: "me"}) |> json_response(200)

      assert %{"error" => "user nobody@example.com not found"} =
               conn
               |> patch("/api/cards/#{card.id}", %{remove_assignees: "nobody@example.com"})
               |> json_response(404)

      assert %{"card" => %{"assignees" => []}} =
               conn
               |> patch("/api/cards/#{card.id}", %{remove_assignees: ["me"]})
               |> json_response(200)
    end
  end

  describe "moving within the board" do
    defp order(column) do
      import Ecto.Query

      Slipdock.Repo.all(
        from(c in Boards.Card,
          where: c.column_id == ^column.id,
          order_by: c.position,
          select: c.title
        )
      )
    end

    test "index takes top, bottom, a number, a numeric string, and anything else as bottom", %{
      conn: conn,
      card: card,
      other: other,
      todo: todo
    } do
      third = card_fixture(todo, %{"title" => "Third"})

      move = fn c, index ->
        conn |> post("/api/cards/#{c.id}/move", %{index: index}) |> json_response(200)
        order(todo)
      end

      assert move.(third, "top") == ["Third", "First", "Second"]
      assert move.(third, "bottom") == ["First", "Second", "Third"]
      assert move.(third, 0) == ["Third", "First", "Second"]
      assert move.(third, "1") == ["First", "Third", "Second"]
      assert move.(third, "middle") == ["First", "Second", "Third"]
      # Not a 500: a JSON number that is not whole, or a boolean, is the end.
      assert move.(card, 1.5) == ["Second", "Third", "First"]
      assert move.(card, true) == ["Second", "Third", "First"]
      assert move.(other, nil) == ["Third", "First", "Second"]
    end

    test "an unknown list is a 404", %{conn: conn, card: card} do
      assert %{"error" => error} =
               conn
               |> post("/api/cards/#{card.id}/move", %{column: "Nowhere"})
               |> json_response(404)

      assert error =~ "column"
    end
  end

  describe "archive, restore and delete" do
    test "archive hides the card, restore brings it back, delete removes it", %{
      conn: conn,
      card: card
    } do
      assert %{"card" => %{"archived_at" => archived_at}} =
               conn |> post("/api/cards/#{card.id}/archive") |> json_response(200)

      assert archived_at
      assert Boards.get_card!(card.id).archived_at

      assert %{"card" => %{"archived_at" => nil}} =
               conn |> post("/api/cards/#{card.id}/restore") |> json_response(200)

      assert %{"ok" => true} = conn |> delete("/api/cards/#{card.id}") |> json_response(200)
      assert Boards.get_card(card.id) == nil
    end

    test "listing leaves archived cards out; archived=true lists them alone, all lists both", %{
      conn: conn,
      board: board,
      card: card,
      other: other
    } do
      {:ok, _} = Boards.archive_card(card)

      ids = fn query ->
        conn
        |> get("/api/boards/#{board.id}/cards#{query}")
        |> json_response(200)
        |> Map.fetch!("cards")
        |> Enum.map(& &1["id"])
      end

      assert ids.("") == [other.id]
      assert ids.("?archived=true") == [card.id]
      assert Enum.sort(ids.("?archived=all")) == Enum.sort([card.id, other.id])
    end
  end

  describe "votes" do
    test "a count that is missing, not a number, negative or over the cap is a 422", %{
      conn: conn,
      card: card
    } do
      assert %{"error" => "count is required"} =
               conn |> post("/api/cards/#{card.id}/vote", %{}) |> json_response(422)

      assert %{"error" => "count must be a whole number"} =
               conn |> post("/api/cards/#{card.id}/vote", %{count: "two"}) |> json_response(422)

      assert %{"error" => "Votes can't be negative."} =
               conn |> post("/api/cards/#{card.id}/vote", %{count: -1}) |> json_response(422)

      assert %{"error" => error} =
               conn |> post("/api/cards/#{card.id}/vote", %{count: 99}) |> json_response(422)

      assert error =~ "At most"
      assert Boards.get_card!(card.id) |> Slipdock.Votes.mine(conn_user(conn)) == 0
    end

    test "a count as a string is read as a number", %{conn: conn, card: card} do
      assert %{"my_votes" => 2} =
               conn |> post("/api/cards/#{card.id}/vote", %{count: "2"}) |> json_response(200)
    end
  end

  defp conn_user(_conn), do: user_fixture()

  describe "links between cards" do
    test "added, refused to itself or with an unknown kind, and removed by id", %{
      conn: conn,
      card: card,
      other: other
    } do
      assert %{"card" => %{"links" => [%{"id" => link_id}]}} =
               conn
               |> post("/api/cards/#{card.id}/links", %{to: other.id, kind: "relates"})
               |> json_response(201)

      assert %{"error" => "A card can't link to itself."} =
               conn
               |> post("/api/cards/#{card.id}/links", %{to: card.id, kind: "relates"})
               |> json_response(422)

      assert %{"error" => "Unknown link kind."} =
               conn
               |> post("/api/cards/#{card.id}/links", %{to: other.id, kind: "loves"})
               |> json_response(422)

      assert %{"error" => "link not found"} =
               conn |> delete("/api/cards/#{card.id}/links/999999999") |> json_response(404)

      # Either end may remove it: the link is found among the incoming ones too.
      assert %{"card" => %{"links" => []}} =
               conn |> delete("/api/cards/#{other.id}/links/#{link_id}") |> json_response(200)
    end

    test "linking to a card the caller cannot read is refused", %{conn: conn, card: card} do
      stranger = user_fixture("cards.stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
      hidden = card_fixture(hd(theirs.columns), %{"title" => "Hidden"})

      assert conn
             |> post("/api/cards/#{card.id}/links", %{to: hidden.id, kind: "relates"})
             |> json_response(403)

      assert Boards.get_card!(card.id).links_out == []
    end
  end

  describe "the smaller contents" do
    test "a comment, a checklist item and a status update land on the card", %{
      conn: conn,
      card: card
    } do
      assert %{"comment" => %{"body" => "Looks fine"}} =
               conn
               |> post("/api/cards/#{card.id}/comments", %{body: "Looks fine"})
               |> json_response(201)

      assert %{"item" => %{"text" => "Write it", "done" => false}} =
               conn
               |> post("/api/cards/#{card.id}/checklist", %{text: "Write it"})
               |> json_response(201)

      assert %{"card" => %{"status_updates" => [%{"health" => "at_risk"}]}} =
               conn
               |> post("/api/cards/#{card.id}/status", %{health: "at_risk", body: "slipping"})
               |> json_response(201)

      card = Boards.get_card!(card.id)
      assert [%{body: "Looks fine"}] = card.comments
      assert [%{text: "Write it"}] = card.checklist_items
    end

    test "a status update with an unknown health is a validation failure", %{
      conn: conn,
      card: card
    } do
      assert %{"error" => "validation failed"} =
               conn
               |> post("/api/cards/#{card.id}/status", %{health: "fine-ish"})
               |> json_response(422)
    end

    test "a card comment is deleted by the shared route; an unknown one is a 404", %{
      conn: conn,
      card: card
    } do
      {:ok, comment} = Boards.add_comment(card, "Typo")

      assert %{"ok" => true} = conn |> delete("/api/comments/#{comment.id}") |> json_response(200)
      assert Boards.get_card!(card.id).comments == []

      for id <- ["999999999", "abc"] do
        assert %{"error" => "item not found"} =
                 conn |> delete("/api/comments/#{id}") |> json_response(404)
      end
    end

    test "someone who can only read cannot remove a link from the card", %{
      card: card,
      board: board
    } do
      {:ok, url} = Boards.add_card_url(card, %{"url" => "https://example.com"})
      reader = user_fixture("cards.reader@example.com")
      share_fixture(board, reader, "read")

      assert conn_as(reader)
             |> put_req_header("accept", "application/json")
             |> delete("/api/cards/#{card.id}/urls/#{url.id}")
             |> json_response(403)

      assert Slipdock.Repo.get(Slipdock.Boards.CardUrl, url.id)
    end
  end

  describe "sub-boards" do
    test "an unknown template is a 404 and no sub-board is made", %{conn: conn, card: card} do
      assert %{"error" => "template not found"} =
               conn
               |> post("/api/cards/#{card.id}/subboard", %{template: "No Such Template"})
               |> json_response(404)

      assert Boards.get_card!(card.id).sub_board == nil
    end
  end
end

defmodule SlipdockWeb.API.CardControllerLimitTest do
  @moduledoc """
  The 402s a card endpoint answers when the owner's account is full. Not
  async: the limit is a server-wide setting.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Settings}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Full"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Archived one"})
    {:ok, _} = Boards.archive_card(card)

    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

    card_fixture(hd(board.columns), %{"title" => "The only one"})

    %{conn: put_req_header(conn, "accept", "application/json"), card: card}
  end

  test "restoring an archived card past the limit is a 402 and it stays archived", %{
    conn: conn,
    card: card
  } do
    body = conn |> post("/api/cards/#{card.id}/restore") |> json_response(402)

    assert body["error"] == "card_limit_reached"
    assert body["retryable"] == false
    assert Boards.get_card!(card.id).archived_at
  end
end
