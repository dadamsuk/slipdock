defmodule SlipdockWeb.CardAuthorsTest do
  @moduledoc """
  Who created a card and who changed it last (#2028) at each door: the card
  panel (sidebar, and the phone's properties), REST `GET /api/cards/:id` and
  MCP `get_card` (`created_by`, `updated_by`, `updated_at`), each reached
  through the door that made the card: the web UI, the CLI as an agent, a
  runner job, MCP and a script's token.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Runners}
  alias Slipdock.Boards.{Activity, Card, CardMove}
  alias Slipdock.Runners.Job

  setup %{user: user} do
    user = Repo.update!(Ecto.Changeset.change(user, name: "Robin Maker"))
    board = board_fixture(%{"name" => "Author doors"}, owner: user)
    [_backlog, todo, _doing, _done] = board.columns
    %{user: user, board: board, todo: todo}
  end

  defp bearer(user, label, headers \\ []) do
    {secret, _} = Accounts.create_api_token(user, label)

    Enum.reduce(
      headers,
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> secret),
      fn {k, v}, conn -> put_req_header(conn, k, v) end
    )
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

  defp rest_card(ctx, id),
    do: conn_as(ctx.user) |> get(~p"/api/cards/#{id}") |> json_response(200) |> Map.get("card")

  defp create_over_rest(conn, ctx, title) do
    conn
    |> post("/api/boards/#{ctx.board.id}/cards", %{title: title})
    |> json_response(201)
    |> get_in(["card", "id"])
  end

  describe "creation, through each door" do
    test "a person in the web UI: the panel and REST name them", ctx do
      {:ok, view, _} =
        live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?rows=flag&cols=column&empty=show")

      view |> element("#swim-cell-1-1 button", "Add") |> render_click()
      view |> form("#swim-cell-1-1 form", %{"title" => "Made on the web"}) |> render_submit()

      card = Repo.one!(from(c in Card, where: c.title == "Made on the web"))
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")

      assert has_element?(view, "#card-created-by", "Created by Robin Maker")
      assert has_element?(view, "#card-created-by-at")
      assert has_element?(view, "#card-changed-by", "Last changed by Robin Maker")

      body = rest_card(ctx, card.id)
      assert %{"kind" => "person", "name" => "Robin Maker"} = body["created_by"]
      assert body["created_by"]["user_id"] == ctx.user.id
    end

    test "an agent over the CLI, by its token's label", ctx do
      conn =
        bearer(ctx.user, "laptop-claude", [
          {"x-slipdock-client", "cli"},
          {"x-slipdock-agent", "1"}
        ])

      id = create_over_rest(conn, ctx, "From the CLI")
      assert %{"kind" => "agent", "name" => "laptop-claude"} = rest_card(ctx, id)["created_by"]
    end

    test "a person at the CLI, by their name", ctx do
      id =
        create_over_rest(bearer(ctx.user, "laptop", [{"x-slipdock-client", "cli"}]), ctx, "Typed")

      assert %{"kind" => "person", "name" => "Robin Maker"} = rest_card(ctx, id)["created_by"]
    end

    test "a script's token over REST, by its label", ctx do
      id = create_over_rest(bearer(ctx.user, "nightly-script"), ctx, "Scripted")
      assert %{"kind" => "agent", "name" => "nightly-script"} = rest_card(ctx, id)["created_by"]
    end

    test "a runner job, by its loop, on every door", ctx do
      {:ok, runner, _} =
        Runners.create_runner(ctx.board, %{"name" => "Dev server", "pool" => "dev"})

      seed = card_fixture(ctx.todo)
      {:ok, _} = Runners.queue(seed, %{pool: "dev", kind: "claude", prompt: "go"})
      %Job{} = job = Runners.claim(runner)

      conn =
        bearer(ctx.user, "bigwhite", [
          {"x-slipdock-client", "cli"},
          {"x-slipdock-agent", "1"},
          {"x-slipdock-job", to_string(job.id)}
        ])

      id = create_over_rest(conn, ctx, "Found while building")

      body = rest_card(ctx, id)

      assert body["created_by"] == %{
               "kind" => "runner",
               "name" => "Dev server loop",
               "user_id" => ctx.user.id,
               "job_id" => job.id
             }

      assert body["updated_by"]["name"] == "Dev server loop"

      card = mcp(conn_as(ctx.user), "get_card", %{card: id})
      assert card["created_by"]["name"] == "Dev server loop"

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{id}")
      assert has_element?(view, "#card-created-by", "Created by Dev server loop")
    end

    test "an agent over MCP, by its token's label", ctx do
      %{"id" => id} =
        mcp(bearer(ctx.user, "claude-desktop"), "create_card", %{
          board: ctx.board.id,
          title: "From MCP"
        })
        |> then(&(&1["card"] || &1))

      card = mcp(conn_as(ctx.user), "get_card", %{card: id})
      assert %{"kind" => "agent", "name" => "claude-desktop"} = card["created_by"]
      assert %{"kind" => "agent", "name" => "claude-desktop"} = card["updated_by"]
      assert is_binary(card["updated_at"])
    end
  end

  describe "the last change, on the doors" do
    setup ctx do
      id = create_over_rest(conn_as(ctx.user), ctx, "Worked on")

      # Everything so far was ten minutes ago.
      past = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(c in Card, where: c.id == ^id), set: [updated_at: past])
      Repo.update_all(from(a in Activity, where: a.card_id == ^id), set: [inserted_at: past])
      %{id: id}
    end

    test "a comment over MCP names the commenter", ctx do
      mcp(bearer(ctx.user, "reviewer-bot"), "comment", %{card: ctx.id, body: "Checked"})

      assert %{"name" => "reviewer-bot"} = rest_card(ctx, ctx.id)["updated_by"]

      assert %{"name" => "reviewer-bot"} =
               mcp(conn_as(ctx.user), "get_card", %{card: ctx.id})["updated_by"]
    end

    test "a field edit over REST names the editor, and moves updated_at", ctx do
      bearer(ctx.user, "triage-script")
      |> patch("/api/cards/#{ctx.id}", %{priority: "high"})
      |> json_response(200)

      body = rest_card(ctx, ctx.id)
      assert %{"name" => "triage-script"} = body["updated_by"]
      {:ok, at, _} = DateTime.from_iso8601(body["updated_at"])
      assert DateTime.diff(DateTime.utc_now(), at) < 60
    end

    test "a move in the web UI names the person, in the sidebar", ctx do
      card = Boards.get_card!(ctx.id)
      [_backlog, _todo, doing, _done] = Boards.get_board!(ctx.board.id).columns
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")

      view
      |> form("#card-title-form", card: %{column_id: doing.id})
      |> render_change()

      assert Repo.get!(Card, card.id).column_id == doing.id
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
      assert has_element?(view, "#card-changed-by", "Last changed by Robin Maker")
    end
  end

  describe "nobody recorded" do
    test "the panel, on a phone too, and the JSON show the time alone", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Old card"})
      Repo.update_all(from(m in CardMove, where: m.card_id == ^card.id), set: [backfilled: true])

      Repo.update_all(from(a in Activity, where: a.card_id == ^card.id),
        set: [actor_kind: nil, actor_name: nil, user_id: nil]
      )

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
      assert has_element?(view, "#card-created-by", "Created")
      refute has_element?(view, "#card-created-by", " by ")
      assert has_element?(view, "#card-created-by-at")
      refute has_element?(view, "#card-changed-by", " by ")
      assert has_element?(view, "#card-changed-by-at")

      {:ok, view, _} = live(phone(ctx.conn), ~p"/boards/#{ctx.board}/cards/#{card.id}")
      assert has_element?(view, "#card-phone-props #card-created-by-at")
      refute has_element?(view, "#card-phone-props #card-created-by", " by ")

      body = rest_card(ctx, card.id)
      assert body["created_by"] == nil
      assert body["updated_by"] == nil
      assert is_binary(body["updated_at"])
    end
  end

  test "the phone's properties name the author too", ctx do
    id = create_over_rest(bearer(ctx.user, "phone-agent"), ctx, "On the go")
    {:ok, view, _} = live(phone(ctx.conn), ~p"/boards/#{ctx.board}/cards/#{id}")
    assert has_element?(view, "#card-phone-props #card-created-by", "Created by phone-agent")
  end
end
