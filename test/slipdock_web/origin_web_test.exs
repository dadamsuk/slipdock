defmodule SlipdockWeb.OriginWebTest do
  @moduledoc """
  Origin on cards (#2778) through every door: the REST API records it and
  refuses a claim, shows it and filters by it; MCP's `create_card` and
  `list_cards` do the same; the card panel shows it and the board's filter
  narrows to it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Origins", "code" => "orig"}, owner: user)
    [_backlog, todo | _] = board.columns
    %{board: board, todo: todo}
  end

  # A request as the CLI makes it from inside runner job `job`.
  defp in_job(conn, job) do
    conn
    |> put_req_header("x-slipdock-client", "cli")
    |> put_req_header("x-slipdock-agent", "1")
    |> put_req_header("x-slipdock-job", to_string(job))
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

  describe "the REST API" do
    test "a job names its generator; the card shows it and the job", ctx do
      card =
        ctx.conn
        |> in_job(42)
        |> post(~p"/api/boards/#{ctx.board.code}/cards", %{"title" => "Fix", "origin" => "sweep"})
        |> json_response(201)
        |> Map.fetch!("card")

      assert {card["origin"], card["origin_job_id"]} == {"sweep", 42}

      shown = ctx.conn |> get(~p"/api/cards/#{card["id"]}") |> json_response(200)
      assert shown["card"]["origin"] == "sweep"
    end

    test "the server records the rest, and refuses a claim", ctx do
      card =
        ctx.conn
        |> post(~p"/api/boards/#{ctx.board.code}/cards", %{"title" => "Mine"})
        |> json_response(201)
        |> Map.fetch!("card")

      # A token with no CLI header is a script: an agent, outside a job.
      assert {card["origin"], card["origin_job_id"]} == {"agent", nil}

      for {conn, claim} <- [{ctx.conn, "sweep"}, {in_job(ctx.conn, 7), "person"}] do
        body =
          conn
          |> post(~p"/api/boards/#{ctx.board.code}/cards", %{"title" => "X", "origin" => claim})
          |> json_response(422)

        assert inspect(body) =~ "only an agent inside a runner job"
      end
    end

    test "cards filter by origin, and a bad one is refused", ctx do
      Boards.Cards.create_card(ctx.todo, %{"title" => "Swept", "origin" => "sweep"},
        actor: Actor.runner(ctx.user, 3)
      )

      Boards.Cards.create_card(ctx.todo, %{"title" => "Mine"}, actor: Actor.web(ctx.user))

      titles = fn origin ->
        ctx.conn
        |> get(~p"/api/boards/#{ctx.board.code}/cards?origin=#{origin}")
        |> json_response(200)
        |> Map.fetch!("cards")
        |> Enum.map(& &1["title"])
      end

      assert titles.("sweep") == ["Swept"]
      assert titles.("person") == ["Mine"]
      assert titles.("none") == []

      assert ctx.conn
             |> get(~p"/api/boards/#{ctx.board.code}/cards?origin=martian")
             |> json_response(400)
             |> inspect() =~ "origin must be one of"
    end
  end

  describe "MCP" do
    test "list_cards filters by origin; create_card can't claim one outside a job", ctx do
      Boards.Cards.create_card(ctx.todo, %{"title" => "Found", "origin" => "findings"},
        actor: Actor.runner(ctx.user, 4)
      )

      Boards.Cards.create_card(ctx.todo, %{"title" => "Mine"}, actor: Actor.web(ctx.user))

      result = mcp(ctx.conn, "list_cards", %{"board" => ctx.board.code, "origin" => "findings"})
      assert result["isError"] == false
      cards = result["structuredContent"]["cards"]
      assert Enum.map(cards, & &1["title"]) == ["Found"]
      assert hd(cards)["origin"] == "findings"

      refused =
        mcp(ctx.conn, "create_card", %{
          "board" => ctx.board.code,
          "title" => "Claimed",
          "origin" => "sweep"
        })

      assert refused["isError"] == true
      assert inspect(refused["content"]) =~ "only an agent inside a runner job"
    end
  end

  describe "the web" do
    test "the card panel shows where it came from", ctx do
      {:ok, card} =
        Boards.Cards.create_card(ctx.todo, %{"title" => "Swept", "origin" => "sweep"},
          actor: Actor.runner(ctx.user, 12)
        )

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")
      assert has_element?(view, "#card-origin[data-origin='sweep (job #12)']")
    end

    test "the board's Origin filter narrows the cards", ctx do
      {:ok, swept} =
        Boards.Cards.create_card(ctx.todo, %{"title" => "Swept", "origin" => "sweep"},
          actor: Actor.runner(ctx.user, 12)
        )

      {:ok, mine} =
        Boards.Cards.create_card(ctx.todo, %{"title" => "Mine"}, actor: Actor.web(ctx.user))

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      view |> element("[phx-click=filter_origin][phx-value-origin=sweep]") |> render_click()
      assert has_element?(view, "#card-#{swept.id}")
      refute has_element?(view, "#card-#{mine.id}")

      # Again clears it.
      view |> element("[phx-click=filter_origin][phx-value-origin=sweep]") |> render_click()
      assert has_element?(view, "#card-#{mine.id}")

      # A value that isn't an origin clears it too, rather than hiding everything.
      view |> element("[phx-click=filter_origin][phx-value-origin=sweep]") |> render_click()
      refute has_element?(view, "#card-#{mine.id}")
      render_click(view, "filter_origin", %{"origin" => "martian"})
      assert has_element?(view, "#card-#{mine.id}")
      assert has_element?(view, "#card-#{swept.id}")
    end
  end
end
