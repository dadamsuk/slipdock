defmodule SlipdockWeb.API.AssigneesTest do
  @moduledoc "Several people on one card, through `/api/cards`."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  setup %{conn: conn} do
    board = board_fixture(%{"name" => "Pairs", "code" => "pairs"})
    card = card_fixture(hd(board.columns), %{"title" => "Pair on it"})
    ada = user_fixture("ada@example.com")
    bob = user_fixture("bob@example.com")

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      card: card,
      ada: ada,
      bob: bob
    }
  end

  defp emails(body), do: Enum.map(body["card"]["assignees"], & &1["email"])

  test "assignees replaces the set, add_ and remove_ edit it, assignee is the lead", %{
    conn: conn,
    card: card
  } do
    path = ~p"/api/cards/#{card.id}"

    body =
      conn
      |> patch(path, %{"assignees" => ["bob@example.com", "ada@example.com"]})
      |> json_response(200)

    assert emails(body) == ["bob@example.com", "ada@example.com"]
    assert body["card"]["assignee"]["email"] == "bob@example.com"

    # "me" is whoever is asking — on a write as on a filter.
    body = conn |> patch(path, %{"add_assignees" => ["me"]}) |> json_response(200)
    assert emails(body) == ["bob@example.com", "ada@example.com", "tester@example.com"]

    body = conn |> patch(path, %{"remove_assignees" => "bob@example.com"}) |> json_response(200)
    assert body["card"]["assignee"]["email"] == "ada@example.com"
    assert Enum.sort(emails(body)) == ["ada@example.com", "tester@example.com"]

    titles = fn q ->
      conn |> get("/api/boards/pairs/cards?" <> q) |> json_response(200) |> Map.fetch!("cards")
    end

    assert [_] = titles.("assignee=me")
    assert [_] = titles.("assignee=ada@example.com")
    assert [] = titles.("assignee=bob@example.com")

    # A single assignee still means just that person, and "" nobody.
    body = conn |> patch(path, %{"assignee" => "bob@example.com"}) |> json_response(200)
    assert emails(body) == ["bob@example.com"]

    body = conn |> patch(path, %{"assignee" => ""}) |> json_response(200)
    assert body["card"]["assignees"] == [] and body["card"]["assignee"] == nil

    assert conn |> patch(path, %{"assignees" => ["nobody@example.com"]}) |> json_response(404)
  end

  test "a card is created with several people on it", %{conn: conn} do
    body =
      conn
      |> post(~p"/api/boards/pairs/cards", %{
        "title" => "Together",
        "assignees" => ["ada@example.com", "bob@example.com"]
      })
      |> json_response(201)

    assert emails(body) == ["ada@example.com", "bob@example.com"]
  end
end
