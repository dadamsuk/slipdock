defmodule SlipdockWeb.API.OpenSubcardsTest do
  @moduledoc """
  Orchestration fixes 5 (#1758) over REST: an agent's token completing a
  card whose sub-board has open cards, by PATCH or by a move into the done
  list, gets a 422 naming them; with them done it completes as before.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Epics", "code" => unique_code()}, owner: user)
    [_backlog, _todo, doing, done] = board.columns
    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    open = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Still to do"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{epic: epic, open: open, done: done, agent: agent}
  end

  test "PATCH completed is a 422 naming the open subcard, and the card stays open", ctx do
    resp =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.epic.id}", %{"completed" => true})
      |> json_response(422)

    assert %{"details" => %{"completed" => [message]}} = resp
    assert message =~ "##{ctx.open.id} Still to do is still open"
    refute Repo.get!(Card, ctx.epic.id).completed
  end

  test "a move into the done list is a 422 naming it", ctx do
    resp =
      ctx.agent
      |> post(~p"/api/cards/#{ctx.epic.id}/move", %{"column" => ctx.done.id})
      |> json_response(422)

    assert resp["error"] =~ "##{ctx.open.id} Still to do is still open"
    card = Repo.get!(Card, ctx.epic.id)
    refute card.completed
    refute card.column_id == ctx.done.id
  end

  test "with the subcard done, PATCH completes it as before", ctx do
    {:ok, _} = Boards.Cards.update_card(ctx.open, %{"completed" => true})

    resp =
      ctx.agent
      |> patch(~p"/api/cards/#{ctx.epic.id}", %{"completed" => true})
      |> json_response(200)

    assert resp["card"]["completed"]
  end
end
