defmodule SlipdockWeb.RecurrenceAPITest do
  @moduledoc """
  Recurring cards over HTTP and MCP (W-1802): set, read (from an earlier
  instance too), skip, stop and list; the card JSON carrying it; and who may
  change one.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Recurrence, Repo}
  alias Slipdock.Boards.Card

  setup %{user: owner} do
    {:ok, owner} = Accounts.update_profile(owner, %{"timezone" => "Europe/London"})
    board = board_fixture(%{}, owner: owner)
    [backlog, _todo, doing | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Review invoices", "due_date" => "2030-01-07"})
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    %{owner: owner, board: board, card: card, doing: doing, reader: reader}
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "limited", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "PUT/GET/DELETE /api/cards/:id/recurrence" do
    test "sets it from a phrase, shows it, and the card JSON carries it", ctx do
      assert %{"recurrence" => r} =
               as(ctx.owner)
               |> put("/api/cards/#{ctx.card.id}/recurrence", %{
                 rule: "every mon",
                 at: "08:30",
                 lead_days: 2,
                 column: ctx.doing.name,
                 ends: "after",
                 count: 4
               })
               |> json_response(200)

      assert r["rule"] == "FREQ=WEEKLY;BYDAY=MO"
      assert r["summary"] == "Every week on Mon, 08:30 Europe/London"
      assert r["at"] == "08:30"
      assert r["timezone"] == "Europe/London"
      assert r["next_on"] == "2030-01-14"
      assert r["next_at"] == "2030-01-12T08:30:00Z"
      assert r["upcoming"] == ["2030-01-14", "2030-01-21", "2030-01-28"]
      assert r["column_id"] == ctx.doing.id
      assert r["ends"] == "after" and r["count"] == 4

      assert %{"current" => true, "recurrence" => %{"id" => id}} =
               as(ctx.owner) |> get("/api/cards/#{ctx.card.id}/recurrence") |> json_response(200)

      assert id == r["id"]

      assert %{
               "card" => %{
                 "recurrence" => %{"rule" => "FREQ=WEEKLY;BYDAY=MO"},
                 "series_id" => ^id
               }
             } =
               as(ctx.owner) |> get("/api/cards/#{ctx.card.id}") |> json_response(200)
    end

    test "an earlier instance points at the series", ctx do
      {:ok, series} = Recurrence.set(ctx.card, %{"rule" => "mon"}, ctx.owner)
      {:ok, _} = Boards.update_card(ctx.card, %{"completed" => true})
      assert Recurrence.tick(~U[2030-01-14 07:00:00Z]) == 1

      assert %{"current" => false, "recurrence" => %{"id" => id, "card_id" => now}} =
               as(ctx.owner) |> get("/api/cards/#{ctx.card.id}/recurrence") |> json_response(200)

      assert id == series.id and now != ctx.card.id

      assert %{"card" => %{"recurrence" => nil, "series_id" => ^id}} =
               as(ctx.owner) |> get("/api/cards/#{ctx.card.id}") |> json_response(200)
    end

    test "a card that doesn't repeat", ctx do
      assert %{"recurrence" => nil, "current" => false} =
               as(ctx.owner) |> get("/api/cards/#{ctx.card.id}/recurrence") |> json_response(200)

      as(ctx.owner) |> delete("/api/cards/#{ctx.card.id}/recurrence") |> json_response(404)
      as(ctx.owner) |> post("/api/cards/#{ctx.card.id}/recurrence/skip") |> json_response(404)
    end

    test "skip and stop", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "mon"}, ctx.owner)

      assert %{"recurrence" => %{"next_on" => "2030-01-21"}} =
               as(ctx.owner)
               |> post("/api/cards/#{ctx.card.id}/recurrence/skip")
               |> json_response(200)

      assert %{"recurrence" => nil} =
               as(ctx.owner)
               |> delete("/api/cards/#{ctx.card.id}/recurrence")
               |> json_response(200)

      assert Recurrence.for_card(ctx.card) == nil
    end

    test "skipping an after-done series with nothing coming is a 422", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "3d after"}, ctx.owner)

      assert %{"error" => "there is no next occurrence to skip"} =
               as(ctx.owner)
               |> post("/api/cards/#{ctx.card.id}/recurrence/skip")
               |> json_response(422)
    end

    test "refuses a rule it can't read, an unknown field, and bad values", ctx do
      assert %{"error" => "rule: " <> _} =
               as(ctx.owner)
               |> put("/api/cards/#{ctx.card.id}/recurrence", %{rule: "now and then"})
               |> json_response(422)

      assert %{"error" => message} =
               as(ctx.owner)
               |> put("/api/cards/#{ctx.card.id}/recurrence", %{rule: "mon", lead: 2})
               |> json_response(400)

      assert message =~ "unknown field(s): lead"

      assert %{"details" => %{"on_missed" => _}} =
               as(ctx.owner)
               |> put("/api/cards/#{ctx.card.id}/recurrence", %{rule: "mon", on_missed: "panic"})
               |> json_response(422)

      assert Recurrence.for_card(ctx.card) == nil
    end

    test "a reader may read but not set, skip or stop; nor may a read-only token", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "mon"}, ctx.owner)
      id = ctx.card.id

      as(ctx.reader) |> get("/api/cards/#{id}/recurrence") |> json_response(200)
      as(ctx.reader) |> put("/api/cards/#{id}/recurrence", %{rule: "tue"}) |> json_response(403)
      as(ctx.reader) |> post("/api/cards/#{id}/recurrence/skip") |> json_response(403)
      as(ctx.reader) |> delete("/api/cards/#{id}/recurrence") |> json_response(403)

      with_token(ctx.owner, scope: "read")
      |> put("/api/cards/#{id}/recurrence", %{rule: "tue"})
      |> json_response(403)

      assert Recurrence.for_card(ctx.card).rule == "FREQ=WEEKLY;BYDAY=MO"
    end

    test "a stranger is refused, as for the card itself", ctx do
      stranger = user_fixture("stranger@example.com")
      as(stranger) |> get("/api/cards/#{ctx.card.id}/recurrence") |> json_response(403)
      as(stranger) |> get("/api/cards/#{ctx.card.id}") |> json_response(403)
    end
  end

  describe "GET /api/boards/:board/recurring" do
    test "lists the board's series, sub-boards included", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "mon"}, ctx.owner)
      card_fixture(hd(ctx.board.columns), %{"title" => "Doesn't repeat"})

      assert %{"recurring" => [row]} =
               as(ctx.reader)
               |> get("/api/boards/#{ctx.board.id}/recurring")
               |> json_response(200)

      assert row["card"] == %{"id" => ctx.card.id, "title" => "Review invoices"}
      assert row["summary"] =~ "Every week on Mon"
    end

    test "a board you can't see is not found", ctx do
      stranger = user_fixture("stranger@example.com")
      as(stranger) |> get("/api/boards/#{ctx.board.id}/recurring") |> json_response(404)
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

    test "update_card sets it alongside other fields, and get_card shows it", ctx do
      assert %{"recurrence" => %{"rule" => "FREQ=MONTHLY;BYDAY=-1FR", "next_on" => _}} =
               as(ctx.owner)
               |> call("update_card", %{
                 card: ctx.card.id,
                 priority: "high",
                 recurrence: %{rule: "month last fri", at: "09:00"}
               })
               |> ok!()

      assert Repo.get!(Card, ctx.card.id).priority == "high"

      assert %{
               "recurrence" => %{
                 "summary" => "Every month on the last Friday, 09:00 Europe/London"
               }
             } =
               as(ctx.owner) |> call("get_card", %{card: ctx.card.id}) |> ok!()
    end

    test "skip: true, and null stops it", ctx do
      {:ok, _} = Recurrence.set(ctx.card, %{"rule" => "mon"}, ctx.owner)

      assert %{"recurrence" => %{"next_on" => "2030-01-21"}} =
               as(ctx.owner)
               |> call("update_card", %{card: ctx.card.id, recurrence: %{skip: true}})
               |> ok!()

      assert %{"recurrence" => nil} =
               as(ctx.owner)
               |> call("update_card", %{card: ctx.card.id, recurrence: nil})
               |> ok!()

      assert Recurrence.for_card(ctx.card) == nil
    end

    test "a bad rule takes the rest of the update back with it", ctx do
      text =
        as(ctx.owner)
        |> call("update_card", %{
          card: ctx.card.id,
          priority: "critical",
          recurrence: %{rule: "whenever"}
        })
        |> error!()

      assert text =~ "recurrence rule:"
      assert Repo.get!(Card, ctx.card.id).priority == "none"
    end

    test "skip on a card that doesn't repeat says so", ctx do
      text =
        as(ctx.owner)
        |> call("update_card", %{card: ctx.card.id, recurrence: %{skip: true}})
        |> error!()

      assert text =~ "doesn't repeat"
    end

    test "a reader and a read-only token can't", ctx do
      assert as(ctx.reader)
             |> call("update_card", %{card: ctx.card.id, recurrence: %{rule: "mon"}})
             |> error!()

      assert with_token(ctx.owner, scope: "read")
             |> call("update_card", %{card: ctx.card.id, recurrence: %{rule: "mon"}})
             |> error!()

      assert Recurrence.for_card(ctx.card) == nil
    end
  end
end
