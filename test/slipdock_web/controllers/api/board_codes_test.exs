defmodule SlipdockWeb.API.BoardCodesTest do
  # Sync: about the codes boards are given, so it uses real ones ("epic",
  # "qvm-1"), and an async test holding the same one would block or deadlock it.
  use SlipdockWeb.ConnCase, async: false

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "accept", "application/json")}
  end

  test "a created board reports its generated code", %{conn: conn} do
    body =
      conn
      |> post(~p"/api/boards", %{"name" => "QVM V1 Remediation"})
      |> json_response(201)

    assert body["board"]["code"] == "qvm-v1-rem"
  end

  test "a code can be given, changed and used to address the board", %{conn: conn} do
    id =
      conn
      |> post(~p"/api/boards", %{"name" => "QVM V1 Remediation", "code" => "QVM 1"})
      |> json_response(201)
      |> get_in(["board", "id"])

    assert %{"board" => %{"id" => ^id, "code" => "qvm-1"}} =
             conn |> get(~p"/api/boards/qvm-1") |> json_response(200)

    assert %{"board" => %{"code" => "qvm-2"}} =
             conn |> patch(~p"/api/boards/#{id}", %{"code" => "qvm-2"}) |> json_response(200)

    assert %{"boards" => [%{"code" => "qvm-2"}]} =
             conn |> get(~p"/api/boards") |> json_response(200)
  end

  test "a clashing code is a validation error", %{conn: conn} do
    conn |> post(~p"/api/boards", %{"name" => "First", "code" => "taken"}) |> json_response(201)

    assert %{"error" => "validation failed", "details" => %{"code" => [message]}} =
             conn
             |> post(~p"/api/boards", %{"name" => "Second", "code" => "taken"})
             |> json_response(422)

    assert message =~ "already used"
  end
end
