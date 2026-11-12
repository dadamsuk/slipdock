defmodule SlipdockWeb.CostWebTest do
  @moduledoc """
  Cost on the card (#1954) at the web doors: `GET /api/cards/:id` and MCP
  `get_card` carry `lead_time` with its `cost` (tokens left out when no log
  carried usage); the card panel's lead-time line; the ledger's REST line
  and page. An idle card has no line on the panel.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.{Job, TranscriptChunk}

  @t0 ~U[2026-11-05 12:00:00Z]

  defp ts(sec), do: @t0 |> DateTime.add(sec, :second) |> DateTime.to_iso8601()

  defp said(sec, id, usage) do
    message = %{id: id, role: "assistant", content: [%{type: "text", text: "Working."}]}
    message = if usage, do: Map.put(message, :usage, usage), else: message
    Jason.encode!(%{type: "assistant", timestamp: ts(sec), message: message})
  end

  # 30s of model; with usage, 1,500 tokens in all.
  defp log(usage?) do
    usage = usage? && %{input_tokens: 1000, output_tokens: 500}
    Enum.join([said(0, "m1", usage), said(30, "m2", nil)], "\n")
  end

  defp job!(card, kind, log) do
    job = working_job_fixture(card, %{kind: kind, status: "done"})
    body = log <> "\n"

    Repo.insert!(%TranscriptChunk{
      job_id: job.id,
      first_line: 0,
      lines: 2,
      bytes: byte_size(body),
      body: body
    })

    Repo.update_all(from(j in Job, where: j.id == ^job.id),
      set: [transcript_lines: 2, transcript_bytes: byte_size(body)]
    )
  end

  setup %{user: user} do
    board = board_fixture(%{"name" => "Cost web", "code" => unique_code()}, owner: user)
    [_backlog, todo, _doing, done] = board.columns
    card = card_fixture(todo, %{"title" => "Priced"})
    job!(card, "claude", log(true))
    job!(card, "verify", log(false))
    %{board: board, todo: todo, done: done, card: card}
  end

  defp with_token(user) do
    {token, _} = Accounts.create_api_token(user, "laptop")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp mcp(conn, name, args) do
    %{"result" => %{"content" => [%{"text" => text}]}} =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: name, arguments: args}
        })
      )
      |> json_response(200)

    Jason.decode!(text)
  end

  describe "a card read on its own" do
    test "the API carries lead_time with the cost by phase", ctx do
      body = ctx.user |> with_token() |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
      lt = body["card"]["lead_time"]

      assert lt["ends"] == "open"
      assert is_integer(lt["seconds"])
      assert lt["rollup"] == nil
      assert lt["cost"]["total"]["jobs"] == 2
      assert lt["cost"]["total"]["model_seconds"] == 60
      assert lt["cost"]["total"]["tokens"]["total"] == 1500
      assert lt["cost"]["phases"]["build"]["tokens"]["input"] == 1000
      # The verify job's log carried no usage: no tokens, not zero.
      refute Map.has_key?(lt["cost"]["phases"]["verify"], "tokens")
    end

    test "MCP get_card carries the same; a card no job ran on has no lead_time", ctx do
      got = ctx.user |> with_token() |> mcp("get_card", %{"card" => ctx.card.id})
      assert got["lead_time"]["cost"]["total"]["tokens"]["output"] == 500

      idle = card_fixture(ctx.todo, %{"title" => "Idle"})
      got = ctx.user |> with_token() |> mcp("get_card", %{"card" => idle.id})
      refute Map.has_key?(got, "lead_time")

      # A job with no log: lead time, but no cost.
      working_job_fixture(idle, %{kind: "claude", status: "done"})
      got = ctx.user |> with_token() |> mcp("get_card", %{"card" => idle.id})
      assert got["lead_time"]["cost"] == nil
      assert is_integer(got["lead_time"]["seconds"])
    end

    test "an epic's lead_time rolls up its subcards", ctx do
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, template)
      [s_todo | _] = Boards.get_board!(sub.id).columns
      job!(card_fixture(s_todo, %{"title" => "Sub"}), "claude", log(true))

      body = ctx.user |> with_token() |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)
      rollup = body["card"]["lead_time"]["rollup"]
      assert rollup["subcards"] == 1
      assert rollup["cost"]["total"]["jobs"] == 3
      assert rollup["cost"]["total"]["tokens"]["total"] == 3000
    end
  end

  describe "the card panel" do
    test "shows lead time and what was spent, by phase", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      assert has_element?(view, "#card-lead-time")

      assert view |> element("#card-lead-time [data-role=cost]") |> render() =~
               "model 1m · tools 0s · 1.5k tokens"

      phases = view |> element("#card-lead-time [data-role=cost-phases]") |> render()
      assert phases =~ "build: model 30s · tools 0s · 1.5k tokens"
      assert phases =~ "verify: model 30s · tools 0s"
      refute phases =~ "verify: model 30s · tools 0s ·"
    end

    test "a card nothing ran on has no lead-time line", %{conn: conn} = ctx do
      idle = card_fixture(ctx.todo, %{"title" => "Idle"})
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{idle.id}")
      refute has_element?(view, "#card-lead-time")
    end
  end

  describe "the ledger" do
    setup ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.card.id),
        set: [completed: true, completed_at: DateTime.utc_now(:second)]
      )

      plain = card_fixture(ctx.done, %{"title" => "Plain"})

      Repo.update_all(from(c in Card, where: c.id == ^plain.id),
        set: [completed: true, completed_at: DateTime.utc_now(:second)]
      )

      %{plain: plain}
    end

    test "the REST line carries the cost, null where no job sent a log", ctx do
      body =
        ctx.user
        |> with_token()
        |> get(~p"/api/boards/#{ctx.board.code}/ledger?since=1")
        |> json_response(200)

      items = Enum.flat_map(body["days"], & &1["items"])
      priced = Enum.find(items, &(&1["card"]["id"] == ctx.card.id))
      assert priced["lead_time"]["cost"]["tokens"]["total"] == 1500
      assert priced["lead_time"]["cost"]["jobs"] == 2
      assert Enum.find(items, &(&1["card"]["id"] == ctx.plain.id))["lead_time"]["cost"] == nil
    end

    test "the page says what was spent beside the lead time", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/boards/#{ctx.board.id}/ledger")

      assert view |> element("[data-role=cost]") |> render() =~
               "spent model 1m · tools 0s · 1.5k tokens"
    end
  end
end
