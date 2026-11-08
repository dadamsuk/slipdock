defmodule SlipdockWeb.OverseerTest do
  @moduledoc """
  The overseer's doors (#2068): `GET`/`PATCH /api/boards/:board/overseer`,
  MCP `get_board overseer: true` and `update_board overseer: {…}`, the
  Overseer section of the board's Automations panel, and its alerts first
  in `GET /api/work`, `GET /api/me` and MCP `whoami`, with the Getting
  Started tour's cards no longer among them.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Overseer, Repo, Work}
  alias Slipdock.Boards.Board

  setup %{user: user} do
    board = board_fixture(%{"name" => "Watched", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    %{board: board, todo: todo, doing: doing}
  end

  defp with_token(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "laptop", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp mcp(conn, name, args) do
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
    |> Map.fetch!("result")
  end

  defp text(%{"content" => [%{"text" => text}]}), do: text

  # A condition open on the board: a wait with nothing running.
  defp waiting(ctx) do
    card = card_fixture(ctx.doing, %{"title" => "Needs you"})
    {:ok, _} = Boards.open_wait(card, Actor.web(ctx.user), %{"needs" => "Which?"})
    {:ok, settings} = Overseer.put_settings(ctx.board, %{"enabled" => true})
    %{fired: [condition]} = Overseer.Watch.run(Repo.get!(Board, ctx.board.id), settings)
    {card, condition}
  end

  describe "REST" do
    test "GET shows it off by default; PATCH turns it on and sets its bounds", ctx do
      conn = with_token(ctx.user)

      body = conn |> get("/api/boards/#{ctx.board.id}/overseer") |> json_response(200)
      assert body["overseer"]["enabled"] == false
      assert body["overseer"]["min_minutes"] == 10
      assert body["overseer"]["max_minutes"] == 120
      assert Enum.map(body["overseer"]["checks"], & &1["key"]) == Overseer.Watch.check_keys()

      body =
        conn
        |> patch("/api/boards/#{ctx.board.code}/overseer", %{
          enabled: true,
          pool: "watch",
          min_minutes: 15,
          max_minutes: 240
        })
        |> json_response(200)

      assert %{"enabled" => true, "pool" => "watch", "min_minutes" => 15, "max_minutes" => 240} =
               body["overseer"]

      assert body["overseer"]["card_id"]
      assert body["overseer"]["next_run_at"]
    end

    test "GET lists the open conditions with why and what to do", ctx do
      {card, condition} = waiting(ctx)

      body =
        ctx.user
        |> with_token()
        |> get("/api/boards/#{ctx.board.id}/overseer")
        |> json_response(200)

      assert [c] = body["overseer"]["conditions"]
      assert c["id"] == condition.id
      assert c["check"] == "waiting_idle"
      assert c["card_id"] == card.id
      assert c["todo"] =~ "Answer the waits"
    end

    test "bad bounds, unknown fields and an empty PATCH are refused", ctx do
      conn = with_token(ctx.user)
      url = "/api/boards/#{ctx.board.id}/overseer"

      assert %{"details" => %{"max_minutes" => [_]}} =
               conn |> patch(url, %{min_minutes: 60, max_minutes: 30}) |> json_response(422)

      assert conn |> patch(url, %{cadence: 5}) |> json_response(422) |> inspect() =~ "cadence"
      assert conn |> patch(url, %{}) |> json_response(422) |> inspect() =~ "nothing to change"
    end

    test "only the owner changes it; a reader may look", ctx do
      reader = user_fixture("overseer-reader@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, reader, "write", ctx.user)
      conn = with_token(reader)

      assert conn |> get("/api/boards/#{ctx.board.id}/overseer") |> json_response(200)

      assert conn
             |> patch("/api/boards/#{ctx.board.id}/overseer", %{enabled: true})
             |> response(403)

      refute Overseer.settings(ctx.board).enabled
    end
  end

  describe "MCP" do
    test "get_board overseer: true reads it; update_board overseer sets it", ctx do
      conn = with_token(ctx.user)

      result =
        conn
        |> mcp("update_board", %{
          board: ctx.board.code,
          overseer: %{enabled: true, max_minutes: 60}
        })

      refute result["isError"]

      assert %{"overseer" => %{"enabled" => true, "max_minutes" => 60}} =
               Jason.decode!(text(result))

      result = mcp(conn, "get_board", %{board: ctx.board.code, overseer: true})

      assert %{"overseer" => %{"enabled" => true, "conditions" => []}} =
               Jason.decode!(text(result))
    end

    test "update_board refuses bad bounds in a sentence", ctx do
      result =
        ctx.user
        |> with_token()
        |> mcp("update_board", %{board: ctx.board.code, overseer: %{min_minutes: 1}})

      assert result["isError"]
      assert text(result) =~ "min_minutes"
    end
  end

  describe "Waiting on you, whoami" do
    test "the overseer's conditions come first, with what to do", ctx do
      older = card_fixture(ctx.todo, %{"title" => "Older wait"})

      {:ok, _} =
        Boards.open_wait(older, Actor.web(user_fixture()), %{
          "needs" => "Old?",
          "on_user_id" => ctx.user.id
        })

      Repo.update_all(Slipdock.Boards.Wait, set: [inserted_at: ~U[2026-01-01 00:00:00Z]])
      {card, _condition} = waiting(ctx)

      [first | _] = Work.waiting_on_me(ctx.user)
      assert first.reason == "overseer"
      assert first.card.id in [card.id, older.id]
      assert first.text =~ "Overseer: Only you can move Watched on"

      conn = with_token(ctx.user)
      body = conn |> get("/api/work") |> json_response(200)
      assert [%{"reason" => "overseer", "condition" => %{"todo" => todo}} | _] = body["waiting"]
      assert todo =~ "Answer the waits"

      me = conn |> get("/api/me") |> json_response(200)
      assert [%{"check" => "waiting_idle"}] = me["overseer"]
      assert me["waiting_on_you"] >= 1

      whoami = conn |> mcp("whoami", %{}) |> text() |> Jason.decode!()
      assert [%{"check" => "waiting_idle"}] = whoami["overseer"]
    end

    test "a Getting Started board's cards don't wait on anyone", ctx do
      tour =
        board_fixture(%{"name" => Slipdock.Onboarding.board_name(), "code" => unique_code()},
          owner: ctx.user
        )

      [_, todo, _, _] = tour.columns

      card =
        card_fixture(todo, %{
          "title" => "Drag this card to Done",
          "flags" => ["review"],
          "assignee_ids" => [ctx.user.id]
        })

      mine =
        card_fixture(ctx.todo, %{
          "title" => "Real work",
          "flags" => ["review"],
          "assignee_ids" => [ctx.user.id]
        })

      ids = Enum.map(Work.waiting_on_me(ctx.user), & &1.card.id)
      assert mine.id in ids
      refute card.id in ids
    end
  end

  describe "the Automations panel" do
    test "the owner turns it on and sees the conditions", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/automations")
      assert has_element?(view, "#board-overseer", "Overseer")
      assert has_element?(view, "#overseer-empty")

      view
      |> form("#overseer-form",
        overseer: %{enabled: "true", min_minutes: "20", max_minutes: "90"}
      )
      |> render_submit()

      assert has_element?(view, "#overseer-notice", "The overseer is on.")
      settings = Overseer.settings(ctx.board)
      assert settings.enabled
      assert {settings.min_minutes, settings.max_minutes} == {20, 90}

      view
      |> form("#overseer-form", overseer: %{min_minutes: "100", max_minutes: "90"})
      |> render_submit()

      assert has_element?(view, "#overseer-notice", "Not saved")
      assert Overseer.settings(ctx.board).min_minutes == 20
    end

    test "open conditions are listed with what to do", %{conn: conn} = ctx do
      {card, condition} = waiting(ctx)
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/automations")

      assert has_element?(
               view,
               "#overseer-condition-#{condition.id}",
               "What to do: Answer the waits"
             )

      assert has_element?(
               view,
               "#overseer-condition-#{condition.id} a[href*='/cards/#{card.id}']"
             )

      refute has_element?(view, "#overseer-empty")
    end

    test "someone who isn't the owner can't change it from the panel", ctx do
      reader = user_fixture("overseer-panel@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, reader, "write", ctx.user)
      conn = build_conn() |> log_in_user(reader)

      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/automations")
      refute has_element?(view, "#overseer-form")
      refute has_element?(view, "#overseer-save")
    end
  end

  describe "a reader of just a sub-board" do
    # The overseer of a sub-board is its root's, whose conditions name the
    # root's cards: reading the sub-board alone shows none of it.
    setup ctx do
      {_card, condition} = waiting(ctx)
      epic = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)

      reader =
        user_fixture("overseer-sub-reader-#{System.unique_integer([:positive])}@example.com")

      %{condition: condition, epic: epic, sub: sub, reader: reader}
    end

    for {how, grant_on} <- [{"a grant on its parent card", :epic}, {"a grant on it", :sub}] do
      test "with #{how}: REST and MCP refuse the root's overseer", ctx do
        {:ok, _} = Slipdock.Access.grant(ctx[unquote(grant_on)], ctx.reader, "read", ctx.user)
        conn = with_token(ctx.reader)

        # The sub-board itself is readable; its overseer is not.
        assert conn |> get("/api/boards/#{ctx.sub.id}") |> json_response(200)

        body = conn |> get("/api/boards/#{ctx.sub.id}/overseer") |> json_response(403)
        assert body["error"] =~ "root board"
        refute inspect(body) =~ "Needs you"

        result = mcp(conn, "get_board", %{board: ctx.sub.code, overseer: true})
        assert result["isError"]
        assert text(result) =~ "root board"
        refute text(result) =~ "Needs you"
      end
    end

    test "the panel shows none of the root's conditions", ctx do
      # The board page opens the Automations panel only for its owner; the
      # component holds the line by itself all the same, rendered here directly.
      {:ok, _} = Slipdock.Access.grant(ctx.epic, ctx.reader, "write", ctx.user)

      html =
        render_component(SlipdockWeb.BoardLive.OverseerComponent,
          id: "board-overseer-panel",
          board: ctx.sub,
          current_user: ctx.reader
        )

      assert html =~ ~s(id="overseer-unreadable")
      refute html =~ "overseer-condition-#{ctx.condition.id}"
      refute html =~ ~s(id="overseer-state")
      refute html =~ "Needs you"
    end

    test "someone who reads the root still sees its overseer through the sub-board", ctx do
      {:ok, _} = Slipdock.Access.grant(ctx.board, ctx.reader, "write", ctx.user)

      body =
        ctx.reader
        |> with_token()
        |> get("/api/boards/#{ctx.sub.id}/overseer")
        |> json_response(200)

      assert [%{"id" => id}] = body["overseer"]["conditions"]
      assert id == ctx.condition.id

      html =
        render_component(SlipdockWeb.BoardLive.OverseerComponent,
          id: "board-overseer-panel",
          board: ctx.sub,
          current_user: ctx.reader
        )

      assert html =~ ~s(id="overseer-condition-#{ctx.condition.id}")
      refute html =~ "overseer-unreadable"
    end
  end
end
