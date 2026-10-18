defmodule SlipdockWeb.SnoozeAPITest do
  @moduledoc """
  Snooze over HTTP and MCP (W-1803): snooze and wake, the card JSON
  carrying it, the list filter, and who may.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Repo, Snooze}
  alias Slipdock.Boards.Card

  setup %{user: owner} do
    {:ok, owner} = Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "Chase the quote"})
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    %{owner: owner, board: board, todo: todo, card: card, reader: reader}
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "limited", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp later_date, do: Date.utc_today() |> Date.add(10) |> Date.to_iso8601()

  describe "POST/DELETE /api/cards/:id/snooze" do
    test "snoozes until midnight where you are, and the card says so", ctx do
      # 1 July 2030: London is on BST.
      assert %{"card" => card} =
               as(ctx.owner)
               |> post("/api/cards/#{ctx.card.id}/snooze", %{
                 until: "2030-07-01",
                 note: "vendor's quote",
                 notify: true,
                 wake_on_activity: false
               })
               |> json_response(200)

      assert card["snoozed_until"] == "2030-06-30T23:00:00Z"

      assert %{
               "until" => "2030-06-30T23:00:00Z",
               "note" => "vendor's quote",
               "notify" => true,
               "wake_on_activity" => false,
               "by_id" => by
             } = card["snooze"]

      assert by == ctx.owner.id

      # get_card and GET /api/cards/:id show it.
      assert %{"card" => %{"snooze" => %{"note" => "vendor's quote"}}} =
               as(ctx.reader) |> get("/api/cards/#{ctx.card.id}") |> json_response(200)
    end

    test "takes a phrase", ctx do
      assert %{"card" => %{"snoozed_until" => until}} =
               as(ctx.owner)
               |> post("/api/cards/#{ctx.card.id}/snooze", %{until: "next week"})
               |> json_response(200)

      assert {:ok, _, _} = DateTime.from_iso8601(until)
    end

    test "DELETE wakes it", ctx do
      {:ok, _} = Snooze.snooze(ctx.card, ctx.owner, later_date())

      assert %{"card" => %{"snoozed_until" => nil, "snooze" => nil}} =
               as(ctx.owner) |> delete("/api/cards/#{ctx.card.id}/snooze") |> json_response(200)

      refute Card.snoozed?(Repo.get!(Card, ctx.card.id))

      assert %{"error" => "the card isn't snoozed"} =
               as(ctx.owner) |> delete("/api/cards/#{ctx.card.id}/snooze") |> json_response(422)
    end

    test "refuses the past, a completed card, a bad date, no date and unknown fields", ctx do
      id = ctx.card.id

      assert %{"error" => "the snooze must end in the future"} =
               as(ctx.owner)
               |> post("/api/cards/#{id}/snooze", %{until: "2020-01-01"})
               |> json_response(422)

      assert %{"error" => "until must be a date" <> _} =
               as(ctx.owner)
               |> post("/api/cards/#{id}/snooze", %{until: "whenever"})
               |> json_response(422)

      assert %{"error" => "until is required" <> _} =
               as(ctx.owner) |> post("/api/cards/#{id}/snooze", %{}) |> json_response(400)

      assert %{"error" => "unknown field(s): notfy" <> _} =
               as(ctx.owner)
               |> post("/api/cards/#{id}/snooze", %{until: later_date(), notfy: true})
               |> json_response(400)

      assert %{"error" => "notify must be true or false"} =
               as(ctx.owner)
               |> post("/api/cards/#{id}/snooze", %{until: later_date(), notify: "loud"})
               |> json_response(400)

      done = card_fixture(ctx.todo, %{"completed" => true})

      assert %{"error" => "a completed card can't be snoozed"} =
               as(ctx.owner)
               |> post("/api/cards/#{done.id}/snooze", %{until: later_date()})
               |> json_response(422)

      refute Card.snoozed?(Repo.get!(Card, id))
    end

    test "a reader can't, nor can a read-only token", ctx do
      id = ctx.card.id

      as(ctx.reader)
      |> post("/api/cards/#{id}/snooze", %{until: later_date()})
      |> json_response(403)

      with_token(ctx.owner, scope: "read")
      |> post("/api/cards/#{id}/snooze", %{until: later_date()})
      |> json_response(403)

      {:ok, _} = Snooze.snooze(ctx.card, ctx.owner, later_date())
      as(ctx.reader) |> delete("/api/cards/#{id}/snooze") |> json_response(403)
      assert Card.snoozed?(Repo.get!(Card, id))
    end
  end

  describe "GET /api/boards/:board/cards?snoozed=" do
    test "left out by default; include, only, and anything else refused", ctx do
      asleep = card_fixture(ctx.todo, %{"title" => "Asleep"})
      {:ok, _} = Snooze.snooze(asleep, ctx.owner, later_date())
      path = "/api/boards/#{ctx.board.id}/cards"

      ids = fn query ->
        as(ctx.owner)
        |> get(path, query)
        |> json_response(200)
        |> Map.fetch!("cards")
        |> Enum.map(& &1["id"])
        |> Enum.sort()
      end

      assert ids.(%{}) == [ctx.card.id]
      assert ids.(%{snoozed: "include"}) == Enum.sort([ctx.card.id, asleep.id])
      assert ids.(%{snoozed: "only"}) == [asleep.id]

      assert %{"error" => "snoozed must be one of: exclude, include, only"} =
               as(ctx.owner) |> get(path, %{snoozed: "maybe"}) |> json_response(400)
    end
  end

  describe "MCP" do
    defp call(conn, tool, args) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: tool, arguments: args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    defp ok!(result) do
      assert result["isError"] == false, inspect(result["content"])
      result["structuredContent"]
    end

    defp error!(result) do
      assert result["isError"] == true
      [%{"text" => text}] = result["content"]
      text
    end

    test "update_card snoozes with a note, changes the note, and null wakes it", ctx do
      assert %{"snoozed_until" => "2030-06-30T23:00:00Z"} =
               as(ctx.owner)
               |> call("update_card", %{
                 card: ctx.card.id,
                 priority: "high",
                 snoozed_until: "2030-07-01",
                 snooze_note: "after the audit"
               })
               |> ok!()

      card = Repo.get!(Card, ctx.card.id)
      assert card.priority == "high"
      assert card.snooze_note == "after the audit"

      as(ctx.owner)
      |> call("update_card", %{card: ctx.card.id, snooze_note: "after the board meeting"})
      |> ok!()

      card = Repo.get!(Card, ctx.card.id)
      assert card.snooze_note == "after the board meeting"
      assert card.snoozed_until == ~U[2030-06-30 23:00:00Z]

      assert %{"snooze" => %{"note" => "after the board meeting"}} =
               as(ctx.owner) |> call("get_card", %{card: ctx.card.id}) |> ok!()

      result =
        as(ctx.owner) |> call("update_card", %{card: ctx.card.id, snoozed_until: nil}) |> ok!()

      refute Map.has_key?(result, "snoozed_until")
      refute Card.snoozed?(Repo.get!(Card, ctx.card.id))
    end

    test "a past date takes the rest of the update back with it", ctx do
      text =
        as(ctx.owner)
        |> call("update_card", %{
          card: ctx.card.id,
          priority: "critical",
          snoozed_until: "2020-01-01"
        })
        |> error!()

      assert text =~ "snooze: the snooze must end in the future"
      assert Repo.get!(Card, ctx.card.id).priority == "none"
    end

    test "a note alone on a card that isn't snoozed says so", ctx do
      text =
        as(ctx.owner)
        |> call("update_card", %{card: ctx.card.id, snooze_note: "hmm"})
        |> error!()

      assert text =~ "isn't snoozed"
    end

    test "list_cards: snoozed exclude by default, include and only; a bad value refused",
         ctx do
      asleep = card_fixture(ctx.todo)
      {:ok, _} = Snooze.snooze(asleep, ctx.owner, later_date())

      ids = fn args ->
        as(ctx.owner)
        |> call("list_cards", Map.put(args, :board, ctx.board.id))
        |> ok!()
        |> Map.fetch!("cards")
        |> Enum.map(& &1["id"])
        |> Enum.sort()
      end

      assert ids.(%{}) == [ctx.card.id]
      assert ids.(%{snoozed: "include"}) == Enum.sort([ctx.card.id, asleep.id])
      assert ids.(%{snoozed: "only"}) == [asleep.id]

      [line] =
        as(ctx.owner)
        |> call("list_cards", %{board: ctx.board.id, snoozed: "only"})
        |> ok!()
        |> Map.fetch!("cards")

      assert line["snoozed_until"]

      assert as(ctx.owner)
             |> call("list_cards", %{board: ctx.board.id, snoozed: "maybe"})
             |> error!() =~ "snoozed must be one of"
    end

    test "a reader and a read-only token can't snooze", ctx do
      assert as(ctx.reader)
             |> call("update_card", %{card: ctx.card.id, snoozed_until: later_date()})
             |> error!()

      assert with_token(ctx.owner, scope: "read")
             |> call("update_card", %{card: ctx.card.id, snoozed_until: later_date()})
             |> error!()

      refute Card.snoozed?(Repo.get!(Card, ctx.card.id))
    end
  end
end
