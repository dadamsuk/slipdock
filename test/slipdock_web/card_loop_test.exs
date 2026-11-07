defmodule SlipdockWeb.CardLoopTest do
  @moduledoc """
  The runner loop holding a card (#2027) at each door: the card panel's
  Assignees and the table's assignee cell (a chip linked to the job), REST
  card JSON and MCP `get_card` / `list_cards` (`loop`). Never an assignee.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Runners}
  alias Slipdock.Runners.Job

  setup %{conn: conn} do
    user = user_fixture()
    board = board_fixture(%{"name" => "Loop doors"}, owner: user)
    [_backlog, _todo, doing, _done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "Mac Studio", "pool" => "dev"})
    card = card_fixture(doing, %{"title" => "Held by a loop"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    %Job{} = job = Runners.claim(runner)
    {:ok, :ok} = Runners.heartbeat(runner, job.id)

    %{conn: conn, user: user, board: board, runner: runner, card: card, job: job}
  end

  defp mcp(conn, tool, args) do
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
    |> get_in(["result", "structuredContent"])
  end

  describe "the card panel" do
    test "shows the loop in Assignees, linked to the job, until the job ends", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      chip = element(view, "#card-assignee-loop")
      assert has_element?(view, "#card-assignee-loop[href='#card-job-#{ctx.job.id}']")
      assert render(chip) =~ "Mac Studio · build"
      assert has_element?(view, "#card-job-#{ctx.job.id}")
      # Nobody is assigned: the picker still says so.
      assert has_element?(view, "#card-assignees option", "Unassigned")

      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: 0})
      send(view.pid, {:jobs_changed, ctx.card.id})
      :sys.get_state(view.pid)
      :sys.get_state(view.pid)

      refute has_element?(view, "#card-assignee-loop")
    end

    test "a person assignee and the loop show side by side", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"assignee_ids" => [ctx.user.id]})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      assert has_element?(view, "#card-assignee-loop", "Mac Studio · build")
      assert has_element?(view, "#card-assignee-#{ctx.user.id}")
    end

    test "a verify job says verify", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: 0})
      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "verify", prompt: "check"})
      %Job{kind: "verify"} = Runners.claim(ctx.runner)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      assert has_element?(view, "#card-assignee-loop", "Mac Studio · verify")
    end
  end

  describe "the table" do
    test "the assignee cell shows the loop, linked to the job on the card", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")

      assert has_element?(
               view,
               "#table-loop-#{ctx.card.id}[href='/boards/#{ctx.board.id}/cards/#{ctx.card.id}#card-job-#{ctx.job.id}']",
               "Mac Studio · build"
             )

      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: 0})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")
      refute has_element?(view, "#table-loop-#{ctx.card.id}")
    end
  end

  describe "REST" do
    test "a card carries loop beside its assignees, and loses it when the job ends", ctx do
      conn = conn_as(ctx.user)
      %{"card" => body} = conn |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)

      assert body["assignees"] == []

      assert body["loop"] == %{
               "runner" => "Mac Studio",
               "kind" => "build",
               "job_id" => ctx.job.id
             }

      listed =
        conn_as(ctx.user)
        |> get(~p"/api/boards/#{ctx.board.id}/cards?assignee=none")
        |> json_response(200)

      assert [%{"loop" => %{"runner" => "Mac Studio"}}] =
               Enum.filter(listed["cards"] || listed, &(&1["id"] == ctx.card.id))

      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: 0})

      %{"card" => body} =
        conn_as(ctx.user) |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200)

      refute Map.has_key?(body, "loop")
    end
  end

  describe "MCP" do
    test "get_card and list_cards carry the loop", ctx do
      card = mcp(conn_as(ctx.user), "get_card", %{card: ctx.card.id})

      assert card["loop"] == %{
               "runner" => "Mac Studio",
               "kind" => "build",
               "job_id" => ctx.job.id
             }

      assert card["assignees"] == []

      %{"cards" => cards} = mcp(conn_as(ctx.user), "list_cards", %{board: ctx.board.id})
      line = Enum.find(cards, &(&1["id"] == ctx.card.id))
      assert line["loop"]["runner"] == "Mac Studio"
      assert line["assignees"] == []
    end
  end
end
