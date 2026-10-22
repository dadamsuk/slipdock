defmodule SlipdockWeb.API.HeaderLinksTest do
  @moduledoc "Header links over HTTP (#1205): /api/header-links."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{HeaderLinks, Vaults}

  setup %{conn: conn, user: user} do
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain #{plan.id}"})
    %{conn: put_req_header(conn, "accept", "application/json"), plan: plan, vault: vault}
  end

  test "lists nothing, and the icons to choose from", %{conn: conn} do
    assert %{"header_links" => [], "icons" => icons} =
             conn |> get(~p"/api/header-links") |> json_response(200)

    assert icons == HeaderLinks.icons()
  end

  test "pins a board by code and a vault by name, then lists both", %{
    conn: conn,
    plan: plan,
    vault: vault
  } do
    assert %{"header_link" => %{"icon" => "star", "board" => %{"id" => plan_id}}} =
             conn
             |> post(~p"/api/header-links", %{board: plan.code, icon: "star"})
             |> json_response(201)

    assert plan_id == plan.id

    assert %{"header_links" => [_, %{"vault" => %{"name" => name}, "icon" => "book-open"}]} =
             conn
             |> post(~p"/api/header-links", %{vault: vault.name, icon: "book-open"})
             |> json_response(201)

    assert name == vault.name
  end

  test "refuses a bad icon, a missing target and a stranger's things", %{
    conn: conn,
    plan: plan
  } do
    assert %{"error" => message} =
             conn
             |> post(~p"/api/header-links", %{board: plan.id, icon: "skull"})
             |> json_response(422)

    assert message =~ "choose an icon"

    assert conn |> post(~p"/api/header-links", %{icon: "star"}) |> json_response(400)

    stranger = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("stranger@example.com"))

    assert conn
           |> post(~p"/api/header-links", %{board: stranger.id, icon: "star"})
           |> json_response(404)

    assert conn
           |> post(~p"/api/header-links", %{vault: "nobody's", icon: "star"})
           |> json_response(404)
  end

  test "moves and removes", %{conn: conn, user: user, plan: plan, vault: vault} do
    {:ok, a} = HeaderLinks.add(user, plan, "star")
    {:ok, b} = HeaderLinks.add(user, vault, "flag")

    assert %{"header_links" => [%{"id" => first}, _]} =
             conn |> patch(~p"/api/header-links/#{a.id}", %{move: "right"}) |> json_response(200)

    assert first == b.id

    assert conn |> patch(~p"/api/header-links/#{a.id}", %{move: "up"}) |> json_response(400)
    assert conn |> patch(~p"/api/header-links/999999999", %{move: "left"}) |> json_response(404)

    assert %{"header_links" => [%{"id" => ^first}]} =
             conn |> delete(~p"/api/header-links/#{a.id}") |> json_response(200)

    assert conn |> delete(~p"/api/header-links/#{a.id}") |> json_response(404)
    assert conn |> delete(~p"/api/header-links/nope") |> json_response(404)
  end
end
