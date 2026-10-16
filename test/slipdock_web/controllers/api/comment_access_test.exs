defmodule SlipdockWeb.API.CommentAccessTest do
  @moduledoc """
  The comment level over HTTP (#863): somebody granted "comment" on a card or
  a page may join its discussion — comment, report a status, leave a vote's
  comment, take back a comment of their own — and is refused everything that
  changes the thing itself, with the same 403 a reader gets.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Commenting", "code" => "commenting"}, owner: owner)
    [todo, doing | _] = board.columns
    card = card_fixture(todo, %{"title" => "Discuss me"})
    other = card_fixture(todo, %{"title" => "Elsewhere"})
    commenter = user_fixture("commenter@example.com")
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    {:ok, _} = Access.grant(board, commenter, "read", owner)
    {:ok, _} = Access.grant(card, commenter, "comment", owner)

    %{
      board: board,
      doing: doing,
      card: card,
      other: other,
      owner: owner,
      commenter: commenter,
      reader: reader
    }
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  describe "a card commenter" do
    test "comments, reports a status and leaves a vote's comment", ctx do
      conn = as(ctx.commenter)

      assert %{"comment" => %{"body" => "My two cents"}} =
               conn
               |> post("/api/cards/#{ctx.card.id}/comments", %{body: "My two cents"})
               |> json_response(201)

      assert %{"card" => _} =
               as(ctx.commenter)
               |> post("/api/cards/#{ctx.card.id}/status", %{health: "at_risk", body: "Hmm"})
               |> json_response(201)

      assert %{"my_votes" => 1} =
               as(ctx.commenter)
               |> post("/api/cards/#{ctx.card.id}/vote", %{count: 1, comment: "Yes please"})
               |> json_response(200)

      assert Repo.one(from(v in Boards.Vote, where: v.card_id == ^ctx.card.id, select: v.comment)) ==
               "Yes please"

      card = Boards.get_card!(ctx.card.id)
      assert [%{body: "My two cents"}] = card.comments
      assert [%{health: "at_risk"}] = card.status_updates
    end

    test "is refused every change to the card itself", ctx do
      {:ok, item} = Boards.add_checklist_item(ctx.card, "Step")
      {:ok, url} = Boards.add_card_url(ctx.card, %{"url" => "https://example.com"})
      id = ctx.card.id

      refusals = [
        {:patch, "/api/cards/#{id}", %{title: "Renamed", due_date: "2030-01-01"}},
        {:patch, "/api/cards/#{id}", %{assignee: ctx.commenter.email}},
        {:post, "/api/cards/#{id}/move", %{column: ctx.doing.id}},
        {:post, "/api/cards/#{id}/archive", %{}},
        {:delete, "/api/cards/#{id}", %{}},
        {:post, "/api/cards/#{id}/timer", %{action: "start"}},
        {:post, "/api/cards/#{id}/checklist", %{text: "More"}},
        {:post, "/api/checklist/#{item.id}/toggle", %{}},
        {:delete, "/api/checklist/#{item.id}", %{}},
        {:post, "/api/cards/#{id}/urls", %{url: "https://example.com/x"}},
        {:delete, "/api/cards/#{id}/urls/#{url.id}", %{}},
        {:post, "/api/cards/#{id}/links", %{to: ctx.other.id, kind: "relates"}},
        {:post, "/api/cards/#{id}/dependencies", %{blocked_by: ctx.other.id}},
        {:delete, "/api/cards/#{id}/dependencies/#{ctx.other.id}", %{}},
        {:post, "/api/cards/#{id}/subboard", %{template: "Simple"}},
        {:post, "/api/cards/#{id}/attachments", %{}}
      ]

      for {method, path, params} <- refusals do
        conn = as(ctx.commenter) |> dispatch(@endpoint, method, path, params)

        assert %{"error" => "forbidden: you don't edit this card"} = json_response(conn, 403),
               "#{method} #{path} should be refused"
      end

      card = Boards.get_card!(id)
      assert card.title == "Discuss me" and card.column_id == hd(ctx.board.columns).id
      assert card.assignees == [] and is_nil(card.archived_at)
      assert [%{done: false}] = card.checklist_items
    end

    test "reaches only the card the grant names", ctx do
      assert %{"error" => "forbidden: you don't comment on this card"} =
               as(ctx.commenter)
               |> post("/api/cards/#{ctx.other.id}/comments", %{body: "Here too?"})
               |> json_response(403)
    end

    test "deletes their own comment but not somebody else's", ctx do
      {:ok, mine} = Boards.add_comment(ctx.card, "Mine", by: ctx.commenter)
      {:ok, theirs} = Boards.add_comment(ctx.card, "Theirs", by: ctx.owner)

      assert %{"error" => "forbidden: you don't edit this card"} =
               as(ctx.commenter) |> delete("/api/comments/#{theirs.id}") |> json_response(403)

      assert %{"ok" => true} =
               as(ctx.commenter) |> delete("/api/comments/#{mine.id}") |> json_response(200)

      assert [%{id: id}] = Boards.get_card!(ctx.card.id).comments
      assert id == theirs.id
    end

    test "loses all of it on a read-only token", ctx do
      {token, _} = Slipdock.Accounts.create_api_token(ctx.commenter, "ro", scope: "read")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "application/json")

      assert %{"error" => error} =
               conn
               |> post("/api/cards/#{ctx.card.id}/comments", %{body: "Nope"})
               |> json_response(403)

      assert error =~ "read-only"
    end
  end

  describe "a plain reader (regression)" do
    test "still can't comment, report a status, or delete their own old comment", ctx do
      {:ok, old} = Boards.add_comment(ctx.card, "From before", by: ctx.reader)

      assert %{"error" => "forbidden: you don't comment on this card"} =
               as(ctx.reader)
               |> post("/api/cards/#{ctx.card.id}/comments", %{body: "Hi"})
               |> json_response(403)

      assert json_response(
               as(ctx.reader) |> post("/api/cards/#{ctx.card.id}/status", %{health: "on_track"}),
               403
             )

      assert json_response(as(ctx.reader) |> delete("/api/comments/#{old.id}"), 403)
    end
  end

  describe "a board-level comment grant" do
    test "makes a commenter on every card, still not an editor", ctx do
      third = user_fixture("boardcommenter@example.com")
      {:ok, _} = Access.grant(ctx.board, third, "comment", ctx.owner)

      for card <- [ctx.card, ctx.other] do
        assert json_response(
                 as(third) |> post("/api/cards/#{card.id}/comments", %{body: "Seen"}),
                 201
               )

        assert json_response(
                 as(third) |> patch("/api/cards/#{card.id}", %{title: "Mine now"}),
                 403
               )
      end
    end
  end

  describe "a page commenter" do
    setup ctx do
      page = page_fixture(ctx.board, %{"title" => "Proposal"}, user: ctx.owner)
      pc = user_fixture("pagecommenter@example.com")
      {:ok, _} = Access.grant(page, pc, "comment", ctx.owner)
      %{page: page, pc: pc}
    end

    test "comments, reports a status and leaves a vote's comment, but edits nothing", ctx do
      id = ctx.page.id

      assert json_response(as(ctx.pc) |> post("/api/pages/#{id}/comments", %{body: "+1"}), 201)

      assert json_response(
               as(ctx.pc) |> post("/api/pages/#{id}/status", %{health: "on_track"}),
               201
             )

      assert json_response(
               as(ctx.pc) |> post("/api/pages/#{id}/vote", %{count: 1, comment: "Agreed"}),
               200
             )

      assert Repo.one(from(v in Boards.Vote, where: v.page_id == ^id, select: v.comment)) ==
               "Agreed"

      for {method, path, params} <- [
            {:patch, "/api/pages/#{id}", %{title: "Hijacked"}},
            {:post, "/api/pages/#{id}/checklist", %{text: "Do it"}},
            {:post, "/api/pages/#{id}/urls", %{url: "https://example.com"}}
          ] do
        assert json_response(as(ctx.pc) |> dispatch(@endpoint, method, path, params), 403),
               "#{method} #{path} should be refused"
      end

      assert Slipdock.Wiki.get_page!(id).title == "Proposal"
    end
  end
end
