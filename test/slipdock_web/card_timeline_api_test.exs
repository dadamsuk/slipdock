defmodule SlipdockWeb.CardTimelineAPITest do
  @moduledoc """
  A card's timeline (#1131) over HTTP (`GET /api/cards/:id/timeline`) and
  MCP (`get_card` with `timeline: true`): the same spans the panel draws,
  refused where the card can't be read.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Runners}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Travelled"})
    :ok = Boards.move_card(card.id, doing.id, nil, actor: Actor.web(owner))

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{}, owner: stranger)
    secret = card_fixture(hd(theirs.columns), %{"title" => "Their card"})

    %{owner: owner, card: card, secret: secret}
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  describe "GET /api/cards/:id/timeline" do
    test "the stays, waits and jobs, each with its seconds", ctx do
      {:ok, _} = Boards.open_wait(ctx.card, Actor.web(ctx.owner), %{"needs" => "OK?"})
      {:ok, job} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
      id = ctx.card.id
      job_id = job.id

      assert %{"card" => ^id, "timeline" => tl} =
               as(ctx.owner) |> get("/api/cards/#{id}/timeline") |> json_response(200)

      assert [todo, doing] = tl["stays"]

      assert %{"list" => "To Do", "category" => "todo", "open" => false, "unsure" => false} =
               todo

      assert %{"how" => %{"kind" => "created"}, "seconds" => s} = todo
      assert is_integer(s)
      assert %{"list" => "In Progress", "open" => true} = doing
      assert %{"kind" => "moved", "actor_kind" => "human", "via" => "web"} = doing["how"]
      assert [%{"needs" => "OK?", "on" => "anyone", "open" => true}] = tl["waits"]
      assert [%{"id" => ^job_id, "status" => "queued", "open" => true}] = tl["jobs"]
      assert is_binary(tl["from"]) and is_binary(tl["to"])
    end

    test "someone else's card is refused, and one that isn't there is not found", ctx do
      assert %{"error" => "forbidden" <> _} =
               as(ctx.owner) |> get("/api/cards/#{ctx.secret.id}/timeline") |> json_response(403)

      assert as(ctx.owner) |> get("/api/cards/999999999/timeline") |> json_response(404)
    end
  end

  describe "MCP get_card" do
    defp call(conn, args) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "get_card", arguments: args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    test "has the timeline only when asked", ctx do
      plain = as(ctx.owner) |> call(%{card: ctx.card.id})
      assert plain["isError"] == false
      refute Map.has_key?(plain["structuredContent"], "timeline")

      asked = as(ctx.owner) |> call(%{card: ctx.card.id, timeline: true})
      assert asked["isError"] == false

      assert %{"stays" => [%{"list" => "To Do"}, %{"list" => "In Progress"}]} =
               asked["structuredContent"]["timeline"]
    end
  end

  describe "the docs" do
    @root Path.expand("../..", __DIR__)
    defp read(path), do: File.read!(Path.join(@root, path))

    test "the guide, README, manual, agents doc and slipdock skill all name it" do
      assert SlipdockWeb.APIGuide.markdown() =~ "GET /api/cards/:id/timeline"

      for path <- ~w(README.md docs/manual.md docs/agents.md) do
        doc = read(path)
        assert doc =~ "/api/cards/:id/timeline", path
        assert doc =~ "slipdock timeline <id>", path
      end

      assert read("docs/manual.md") =~ "`get_card` with\n`timeline: true`"
      assert read("priv/skills/slipdock/SKILL.md") =~ "slipdock timeline <id>"
    end

    test "/help/agents says how to read it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents/runners")
      assert html =~ "Timeline."
      assert html =~ "slipdock timeline &lt;id&gt;"
    end
  end
end
