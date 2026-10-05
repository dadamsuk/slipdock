defmodule SlipdockWeb.MCP.TransportTest do
  @moduledoc """
  `/mcp` as a transport: the handshake, JSON-RPC framing and errors, the
  bearer auth and its challenge, and the HTTP rules of stateless Streamable
  HTTP (W-21). The tools themselves are tested beside them.
  """
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Accounts

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    raw(conn, Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}))
  end

  defp raw(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  describe "initialize" do
    test "agrees the client's revision and points at the guide", %{conn: conn} do
      body =
        conn
        |> rpc("initialize", %{
          protocolVersion: "2025-06-18",
          capabilities: %{},
          clientInfo: %{name: "test", version: "1"}
        })
        |> json_response(200)

      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => result} = body
      assert result["protocolVersion"] == "2025-06-18"
      assert result["capabilities"] == %{"tools" => %{"listChanged" => false}}
      assert result["serverInfo"]["name"] == "slipdock"
      assert result["instructions"] =~ "get_guide"
      assert result["instructions"] =~ "/api/guide"
    end

    test "answers an unknown revision with the newest it speaks", %{conn: conn} do
      result =
        conn |> rpc("initialize", %{protocolVersion: "2099-01-01"}) |> json_response(200)

      assert result["result"]["protocolVersion"] == "2025-11-25"
    end

    test "issues no session", %{conn: conn} do
      conn = rpc(conn, "initialize", %{protocolVersion: "2025-11-25"})
      assert get_resp_header(conn, "mcp-session-id") == []
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end
  end

  test "ping answers an empty result", %{conn: conn} do
    assert %{"id" => "p", "result" => %{}} = conn |> rpc("ping", %{}, "p") |> json_response(200)
  end

  describe "JSON-RPC errors" do
    test "an unknown method is -32601", %{conn: conn} do
      body = conn |> rpc("resources/list") |> json_response(200)
      assert body["id"] == 1
      assert body["error"]["code"] == -32601
      assert body["error"]["message"] =~ "resources/list"
    end

    test "a body that is not JSON is a -32700 parse error", %{conn: conn} do
      body = conn |> raw("{not json") |> json_response(400)
      assert body["error"]["code"] == -32700
      assert body["id"] == nil
    end

    test "a batch is refused: one message per POST", %{conn: conn} do
      batch = Jason.encode!([%{jsonrpc: "2.0", id: 1, method: "ping"}])
      assert %{"error" => %{"code" => -32600}} = conn |> raw(batch) |> json_response(400)
    end

    test "a message without jsonrpc 2.0 is an invalid request", %{conn: conn} do
      body = conn |> raw(Jason.encode!(%{id: 7, method: "ping"})) |> json_response(400)
      assert body["error"]["code"] == -32600
      assert body["id"] == 7
    end

    test "a JSON value that is not an object is an invalid request", %{conn: conn} do
      assert %{"error" => %{"code" => -32600}} = conn |> raw("42") |> json_response(400)
    end

    test "tools/call without a name is -32602", %{conn: conn} do
      assert %{"error" => %{"code" => -32602}} =
               conn |> rpc("tools/call", %{arguments: %{}}) |> json_response(200)
    end

    test "an unknown tool is -32602", %{conn: conn} do
      body = conn |> rpc("tools/call", %{name: "drop_tables"}) |> json_response(200)
      assert body["error"]["code"] == -32602
      assert body["error"]["message"] =~ "drop_tables"
    end
  end

  describe "notifications" do
    test "are accepted with 202 and no body", %{conn: conn} do
      conn = raw(conn, Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"}))
      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "a response from the client is accepted too", %{conn: conn} do
      conn = raw(conn, Jason.encode!(%{jsonrpc: "2.0", id: 3, result: %{}}))
      assert conn.status == 202
    end
  end

  describe "auth" do
    @tag :anonymous
    test "no token is a 401 that says where to sign in", %{conn: conn} do
      conn = rpc(conn, "initialize", %{protocolVersion: "2025-11-25"})

      assert json_response(conn, 401)["error"] =~ "unauthorized"
      assert [challenge] = get_resp_header(conn, "www-authenticate")

      assert challenge ==
               ~s(Bearer resource_metadata="http://www.example.com/.well-known/oauth-protected-resource/mcp", scope="write")
    end

    @tag :anonymous
    test "a bad token is a 401 with the challenge", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer nonsense") |> rpc("ping")
      assert conn.status == 401
      assert [_] = get_resp_header(conn, "www-authenticate")
    end

    @tag :anonymous
    test "a revoked token stops working", %{conn: conn, user: user} do
      {token, row} = Accounts.create_api_token(user, "agent")
      conn = put_req_header(conn, "authorization", "Bearer " <> token)
      assert conn |> rpc("ping") |> json_response(200)

      Accounts.delete_api_token(user, row.id)
      assert conn |> rpc("ping") |> response(401)
    end

    @tag :anonymous
    test "a read-only token can still call over POST", %{conn: conn, user: user} do
      {token, _} = Accounts.create_api_token(user, "agent", scope: "read")
      conn = put_req_header(conn, "authorization", "Bearer " <> token)

      assert %{"result" => %{"tools" => _}} = conn |> rpc("tools/list") |> json_response(200)
    end
  end

  describe "HTTP" do
    test "GET is 405: no server-to-client stream", %{conn: conn} do
      conn = get(conn, "/mcp")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "DELETE is 405: there are no sessions to end", %{conn: conn} do
      assert conn |> delete("/mcp") |> response(405)
    end

    test "a foreign Origin is refused (DNS rebinding)", %{conn: conn} do
      conn = conn |> put_req_header("origin", "https://evil.example") |> rpc("ping")
      assert conn.status == 403
    end

    test "this server's own Origin is let through", %{conn: conn} do
      conn = conn |> put_req_header("origin", "http://localhost:4000") |> rpc("ping")
      assert json_response(conn, 200)["result"] == %{}
    end

    test "an unsupported MCP-Protocol-Version is a 400 listing the supported ones",
         %{conn: conn} do
      body =
        conn
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> rpc("ping")
        |> json_response(400)

      assert body["error"]["data"]["supported"] == SlipdockWeb.MCP.Plug.versions()
    end

    test "a supported MCP-Protocol-Version is accepted", %{conn: conn} do
      assert conn
             |> put_req_header("mcp-protocol-version", "2025-11-25")
             |> rpc("ping")
             |> json_response(200)
    end

    test "a body over the limit is 413", %{conn: conn} do
      big =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "ping",
          params: %{pad: String.duplicate("x", 1_100_000)}
        })

      assert conn |> raw(big) |> response(413)
    end
  end

  describe "tools/list and whoami" do
    test "lists whoami as read-only", %{conn: conn} do
      tools = conn |> rpc("tools/list") |> json_response(200) |> get_in(["result", "tools"])
      whoami = Enum.find(tools, &(&1["name"] == "whoami"))

      assert whoami["annotations"]["readOnlyHint"] == true
      assert whoami["inputSchema"]["type"] == "object"
    end

    @tag :anonymous
    test "whoami answers the token's own user and scope", %{conn: conn, user: user} do
      {token, _} = Accounts.create_api_token(user, "Claude", scope: "read")

      result =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> rpc("tools/call", %{name: "whoami", arguments: %{}})
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["isError"] == false
      assert result["structuredContent"]["user"]["email"] == user.email

      assert result["structuredContent"]["token"] == %{
               "label" => "Claude",
               "scope" => "read",
               "boards" => []
             }

      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert Jason.decode!(text)["user"]["id"] == user.id
    end

    test "arguments that are not an object are a tool error", %{conn: conn} do
      result =
        conn
        |> rpc("tools/call", %{name: "whoami", arguments: [1, 2]})
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["isError"] == true
    end
  end
end
