defmodule Slipdock.BoardsCreatedActorTest do
  @moduledoc """
  Who a card's `created` ledger row names (#2094): the actor the write's opts
  give, else the process's (`Slipdock.Actor.current/0`, the person behind a
  LiveView), as its activity row already is. The board page's quick add
  passes no actor, so before this its row read as unknown, and so did
  `CardState`'s driver.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.{Activity, Card, CardMove}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Made", "code" => "made"}, owner: user)
    [_backlog, todo | _] = board.columns
    on_exit(fn -> Actor.put(nil) end)
    %{conn: conn, user: user, board: board, todo: todo}
  end

  defp created_move(card),
    do: Repo.one!(from(m in CardMove, where: m.card_id == ^card.id and m.kind == "created"))

  defp card_titled(board, title),
    do: Repo.one!(from(c in Card, where: c.board_id == ^board.id and c.title == ^title))

  defp first_activity(card),
    do: Repo.one!(from(a in Activity, where: a.card_id == ^card.id, order_by: a.id, limit: 1))

  # A runner rule makes the tree one whose cards say who drives them.
  defp runner_tree(board) do
    {:ok, _runner, _} = Runners.create_runner(board, %{"name" => "runner-1", "pool" => "dev"})

    rule_fixture(board, %{
      "trigger" => %{"type" => "card_created"},
      "actions" => [%{"type" => "runner", "pool" => "dev"}]
    })
  end

  defp state_of(board, card),
    do: board |> Boards.Cards.list_cards() |> Enum.find(&(&1.id == card.id)) |> Map.fetch!(:state)

  describe "a card made on the board page" do
    test "quick add stamps its created row with the person, as its activity row is", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      render_hook(view, "quick_add_card", %{"title" => "From the web", "column_id" => ctx.todo.id})

      card = card_titled(ctx.board, "From the web")
      move = created_move(card)
      assert move.actor_kind == "human"
      assert move.via == "web"
      assert move.user_id == ctx.user.id
      assert move.to_column_id == ctx.todo.id

      # The activity log's word for a person is "person"; the ledger's "human".
      activity = first_activity(card)
      assert activity.actor_kind == "person"
      assert activity.user_id == move.user_id
    end

    test "CardState's driver reads it as made by a person", ctx do
      runner_tree(ctx.board)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      render_hook(view, "quick_add_card", %{"title" => "Driven", "column_id" => ctx.todo.id})

      card = card_titled(ctx.board, "Driven")
      assert state_of(ctx.board, card).driver == "human"
      assert [%{id: id}] = Boards.Cards.list_cards(ctx.board, %{"driver" => "human"})
      assert id == card.id
      assert Boards.Cards.list_cards(ctx.board, %{"driver" => "agent"}) == []
    end
  end

  describe "the actor a create falls back to" do
    test "the process's, when the opts name nobody", ctx do
      Actor.put(Actor.web(ctx.user), "Robin")
      {:ok, card} = Boards.Cards.create_card(ctx.todo, %{"title" => "Process"})

      assert %{actor_kind: "human", via: "web", user_id: id} = created_move(card)
      assert id == ctx.user.id
    end

    test "the opts' actor wins over the process's", ctx do
      Actor.put(Actor.web(ctx.user))
      agent = Actor.mcp(%{user: ctx.user, token: %{label: "claude"}})
      {:ok, card} = Boards.Cards.create_card(ctx.todo, %{"title" => "Opts"}, actor: agent)

      assert %{actor_kind: "agent", via: "mcp", agent: "claude"} = created_move(card)
    end

    test "with nobody anywhere it stays unknown, never guessed", ctx do
      {:ok, card} = Boards.Cards.create_card(ctx.todo, %{"title" => "Nobody"})
      assert %{actor_kind: nil, via: nil, user_id: nil} = created_move(card)
    end

    test "with nobody but `:by`, the person is kept on the row", ctx do
      {:ok, card} = Boards.Cards.create_card(ctx.todo, %{"title" => "By"}, by: ctx.user)
      assert created_move(card).user_id == ctx.user.id
    end
  end

  describe "a card made over the API" do
    defp api(user, headers) do
      {token, _} = Accounts.create_api_token(user, "agent", [])

      Enum.reduce(
        headers,
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "application/json"),
        fn {k, v}, conn -> put_req_header(conn, k, v) end
      )
    end

    test "a script's token is an agent on the created row", ctx do
      ctx.user
      |> api([])
      |> post("/api/boards/made/cards", %{title: "Scripted"})
      |> json_response(201)

      card = card_titled(ctx.board, "Scripted")
      assert %{actor_kind: "agent", via: "api", agent: "agent", user_id: id} = created_move(card)
      assert id == ctx.user.id
    end

    test "a person at the CLI is a person, and drives the card", ctx do
      runner_tree(ctx.board)

      ctx.user
      |> api([{"x-slipdock-client", "cli"}])
      |> post("/api/boards/made/cards", %{title: "Typed"})
      |> json_response(201)

      card = card_titled(ctx.board, "Typed")
      assert %{actor_kind: "human", via: "cli"} = created_move(card)
      assert state_of(ctx.board, card).driver == "human"
    end
  end
end
