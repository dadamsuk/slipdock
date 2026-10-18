defmodule SlipdockWeb.API.HotkeysTest do
  @moduledoc "GET /api/hotkeys and PUT /api/boards/:board/hotkey (#1101)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Hotkeys

  setup %{conn: conn, user: user} do
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    ops = board_fixture(%{"name" => "Ops"}, owner: user)
    %{conn: put_req_header(conn, "accept", "application/json"), plan: plan, ops: ops}
  end

  test "starts empty; a put gives the board its digit and lists it", %{conn: conn, plan: plan} do
    assert %{"hotkeys" => []} = conn |> get(~p"/api/hotkeys") |> json_response(200)

    assert %{"board_id" => id, "digit" => 1, "hotkeys" => [entry]} =
             conn |> put(~p"/api/boards/#{plan.code}/hotkey", %{digit: "1"}) |> json_response(200)

    assert id == plan.id

    assert entry == %{
             "digit" => 1,
             "board" => %{"id" => plan.id, "name" => "Plan", "code" => plan.code}
           }

    assert %{"hotkeys" => [^entry]} = conn |> get(~p"/api/hotkeys") |> json_response(200)
  end

  test "a digit another board had moves; null takes it away",
       %{conn: conn, user: user, plan: plan, ops: ops} do
    {:ok, 2} = Hotkeys.put(user, plan, 2)

    assert %{"hotkeys" => [%{"digit" => 2, "board" => %{"id" => ops_id}}]} =
             conn |> put(~p"/api/boards/#{ops.id}/hotkey", %{digit: 2}) |> json_response(200)

    assert ops_id == ops.id
    assert Hotkeys.get(user, plan) == nil

    assert %{"digit" => nil, "hotkeys" => []} =
             conn |> put(~p"/api/boards/#{ops.id}/hotkey", %{digit: nil}) |> json_response(200)
  end

  test "a bad digit is a 422, a missing one a 400", %{conn: conn, user: user, plan: plan} do
    assert %{"error" => message} =
             conn |> put(~p"/api/boards/#{plan.id}/hotkey", %{digit: "12"}) |> json_response(422)

    assert message =~ "single digit"

    assert %{"error" => missing} =
             conn |> put(~p"/api/boards/#{plan.id}/hotkey", %{}) |> json_response(400)

    assert missing =~ "digit is required"
    assert Hotkeys.list(user) == []
  end

  test "a board the caller cannot open is not found", %{conn: conn, user: user} do
    theirs = board_fixture(%{"name" => "Theirs"}, owner: user_fixture("owner@example.com"))
    conn |> put(~p"/api/boards/#{theirs.id}/hotkey", %{digit: 1}) |> json_response(404)
    assert Hotkeys.list(user) == []
  end

  test "read access is enough, and takes nothing from the owner", %{conn: conn, user: user} do
    owner = user_fixture("owner@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: owner)
    share_fixture(theirs, user, "read")
    {:ok, 1} = Hotkeys.put(owner, theirs, 1)

    assert %{"digit" => 3} =
             conn |> put(~p"/api/boards/#{theirs.id}/hotkey", %{digit: 3}) |> json_response(200)

    assert Hotkeys.get(owner, theirs) == 1
    assert Hotkeys.get(user, theirs) == 3
  end
end
