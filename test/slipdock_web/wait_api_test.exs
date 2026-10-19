defmodule SlipdockWeb.WaitAPITest do
  @moduledoc """
  Waiting on a person over HTTP (#1114): `POST /api/cards/:id/wait` opens
  one, `POST …/wait/answer` answers it, `DELETE …/wait` withdraws it, and
  `GET /api/cards/:id` shows it while open and as `last_wait` after. Who may
  do which, the agent's own question, and taking the flag off by hand.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Repo}
  alias Slipdock.Boards.Wait

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Deploy"})

    dana =
      "dana@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(name: "Dana")
      |> Repo.update!()

    commenter = user_fixture("commenter@example.com")
    {:ok, _} = Access.grant(board, dana, "write", owner)
    {:ok, _} = Access.grant(board, commenter, "read", owner)
    {:ok, _} = Access.grant(card, commenter, "comment", owner)
    %{board: board, card: card, owner: owner, dana: dana, commenter: commenter}
  end

  defp token(user, label, headers \\ []) do
    {token, _} = Accounts.create_api_token(user, label)

    Enum.reduce(
      headers,
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token),
      fn {k, v}, conn -> put_req_header(conn, k, v) end
    )
  end

  # One token, as a person at the command line and as the agent on it.
  defp cli(user, label \\ "laptop"), do: token(user, label, [{"x-slipdock-client", "cli"}])

  defp open(conn, card, params),
    do: post(conn, "/api/cards/#{card.id}/wait", params)

  describe "POST /api/cards/:id/wait" do
    test "opens a wait on a person, with choices, flagging the card", ctx do
      assert %{"wait" => wait} =
               token(ctx.owner, "bot")
               |> open(ctx.card, %{
                 needs: "Which region?",
                 on: ctx.dana.email,
                 choices: ["eu", "us"]
               })
               |> json_response(201)

      assert %{
               "needs" => "Which region?",
               "choices" => ["eu", "us"],
               "on" => %{"name" => "Dana"},
               "kind" => "agent",
               "via" => "api",
               "agent" => "bot",
               "set_flag" => true,
               "open" => true,
               "job_id" => nil
             } = wait

      card = token(ctx.owner, "r") |> get("/api/cards/#{ctx.card.id}") |> json_response(200)
      assert "waiting" in card["card"]["flags"]
      assert card["card"]["wait"]["id"] == wait["id"]
      assert card["card"]["last_wait"] == nil
    end

    test "a second is a 409 naming the first; an unknown person is a 422", ctx do
      open(token(ctx.owner, "bot"), ctx.card, %{needs: "Which region?"})

      assert %{"error" => error} =
               token(ctx.owner, "bot")
               |> open(ctx.card, %{needs: "Size?"})
               |> json_response(409)

      assert error =~ "already has an open wait: “Which region?”"

      other = card_fixture(hd(ctx.board.columns))

      assert %{"error" => "on: nobody who can open card " <> _} =
               token(ctx.owner, "bot")
               |> open(other, %{needs: "Size?", on: "nobody@example.com"})
               |> json_response(422)
    end

    test "a commenter may not open one; nor may a read-only token", ctx do
      assert token(ctx.commenter, "c") |> open(ctx.card, %{needs: "Mine?"}) |> json_response(403)

      {ro, _} = Accounts.create_api_token(ctx.owner, "ro", scope: "read")

      assert build_conn()
             |> put_req_header("accept", "application/json")
             |> put_req_header("authorization", "Bearer " <> ro)
             |> open(ctx.card, %{needs: "Mine?"})
             |> json_response(403)

      assert Repo.aggregate(Wait, :count) == 0
    end
  end

  describe "POST /api/cards/:id/wait/answer" do
    setup ctx do
      conn = cli(ctx.owner) |> put_req_header("x-slipdock-agent", "1")
      open(conn, ctx.card, %{needs: "Which region?", on: ctx.dana.email, choices: ["eu", "us"]})
      :ok
    end

    test "Dana answers by choice and in words; get_card then shows last_wait", ctx do
      assert %{"wait" => wait} =
               token(ctx.dana, "phone")
               |> post("/api/cards/#{ctx.card.id}/wait/answer", %{choice: 1, answer: "for now"})
               |> json_response(200)

      assert %{
               "open" => false,
               "close_reason" => "answered",
               "choice" => 1,
               "choice_text" => "eu",
               "answer" => "for now",
               "closed_by" => %{"name" => "Dana"}
             } = wait

      card = token(ctx.owner, "r") |> get("/api/cards/#{ctx.card.id}") |> json_response(200)
      assert card["card"]["wait"] == nil
      assert card["card"]["last_wait"]["id"] == wait["id"]
      refute "waiting" in card["card"]["flags"]
    end

    test "the agent that asked can't answer; the same token without the agent header can",
         ctx do
      assert %{"error" => "an agent can't answer" <> _} =
               cli(ctx.owner)
               |> put_req_header("x-slipdock-agent", "1")
               |> post("/api/cards/#{ctx.card.id}/wait/answer", %{answer: "eu"})
               |> json_response(422)

      assert %{"wait" => %{"close_reason" => "answered"}} =
               cli(ctx.owner)
               |> post("/api/cards/#{ctx.card.id}/wait/answer", %{answer: "eu"})
               |> json_response(200)
    end

    test "the second answer is a 409 saying who answered first", ctx do
      token(ctx.dana, "p") |> post("/api/cards/#{ctx.card.id}/wait/answer", %{answer: "eu"})

      assert %{"error" => error} =
               token(ctx.owner, "o")
               |> post("/api/cards/#{ctx.card.id}/wait/answer", %{answer: "us"})
               |> json_response(409)

      assert error =~ "already answered by Dana at"
    end

    test "a commenter may not answer", ctx do
      assert token(ctx.commenter, "c")
             |> post("/api/cards/#{ctx.card.id}/wait/answer", %{answer: "eu"})
             |> json_response(403)

      assert Wait.open?(Boards.current_wait(ctx.card))
    end
  end

  describe "DELETE /api/cards/:id/wait and the flag" do
    test "withdraws it, and a second withdraw is a 422", ctx do
      open(token(ctx.owner, "bot"), ctx.card, %{needs: "Which region?"})

      assert %{"wait" => %{"close_reason" => "withdrawn"}} =
               token(ctx.owner, "bot")
               |> delete("/api/cards/#{ctx.card.id}/wait")
               |> json_response(200)

      assert %{"error" => "card #" <> _} =
               token(ctx.owner, "bot")
               |> delete("/api/cards/#{ctx.card.id}/wait")
               |> json_response(422)
    end

    test "whoever opened it may withdraw it without write on the card", ctx do
      {:ok, _} =
        Boards.open_wait(ctx.card, Slipdock.Actor.web(ctx.commenter), %{"needs" => "Mine?"})

      assert %{"wait" => %{"close_reason" => "withdrawn"}} =
               token(ctx.commenter, "c")
               |> delete("/api/cards/#{ctx.card.id}/wait")
               |> json_response(200)
    end

    test "remove_flags waiting withdraws it, saying who (AE4)", ctx do
      open(token(ctx.owner, "bot"), ctx.card, %{needs: "Which region?"})

      token(ctx.dana, "p")
      |> patch("/api/cards/#{ctx.card.id}", %{remove_flags: ["waiting"]})
      |> json_response(200)

      assert %{close_reason: "withdrawn", closed_by_id: id} = Boards.last_wait(ctx.card)
      assert id == ctx.dana.id

      assert Enum.any?(
               Boards.get_card!(ctx.card.id).comments,
               &(&1.body ==
                   "Dana took the waiting flag off, which withdrew the wait “Which region?”")
             )
    end
  end

  test "a card with no wait has no wait key in listings", ctx do
    %{"cards" => [card]} =
      token(ctx.owner, "r") |> get("/api/boards/#{ctx.board.id}/cards") |> json_response(200)

    refute Map.has_key?(card, "wait")
  end
end
