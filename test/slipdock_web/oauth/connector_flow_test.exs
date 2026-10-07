defmodule SlipdockWeb.OAuth.ConnectorFlowTest do
  @moduledoc """
  The whole of what a connector such as claude.ai does with nothing but the
  `/mcp` address (#335): be refused with a challenge, follow it to the
  metadata, register, send the person to the consent page, exchange the code,
  then initialize and call tools — and, an hour later, refresh and carry on.
  Each step reads the address of the next from the previous answer, the way a
  client must, so a broken link anywhere in the chain fails here.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.Accounts.UserToken
  alias Slipdock.Repo

  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery"}, owner: user)

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    {:ok,
     browser: Plug.Conn.delete_req_header(conn, "authorization"),
     user: user,
     board: board,
     verifier: verifier,
     challenge: challenge}
  end

  defp anonymous, do: build_conn()

  defp path(url), do: URI.parse(url).path

  defp rpc(token, method, params) do
    conn =
      anonymous()
      |> put_req_header("content-type", "application/json")
      |> then(fn c ->
        if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
      end)
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))

    conn
  end

  defp call_tool(token, name, args) do
    token
    |> rpc("tools/call", %{name: name, arguments: args})
    |> json_response(200)
    |> Map.fetch!("result")
  end

  # From the 401 to an access token, as a connector would. `scope` is what the
  # person leaves selected on the consent page.
  defp connect_app(ctx, scope) do
    # 1. Refused, with a pointer to the resource metadata.
    conn = rpc(nil, "initialize", %{protocolVersion: "2025-11-25"})
    assert conn.status == 401
    [challenge] = get_resp_header(conn, "www-authenticate")
    [_, resource_metadata] = Regex.run(~r/resource_metadata="([^"]+)"/, challenge)

    # 2. The resource names its authorization server; that server's metadata
    #    names every endpoint from here on.
    resource = anonymous() |> get(path(resource_metadata)) |> json_response(200)
    [issuer] = resource["authorization_servers"]

    meta =
      anonymous() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

    assert meta["issuer"] == issuer
    assert "S256" in meta["code_challenge_methods_supported"]

    # 3. Dynamic client registration.
    registered =
      anonymous()
      |> put_req_header("content-type", "application/json")
      |> post(
        path(meta["registration_endpoint"]),
        Jason.encode!(%{
          client_name: "Claude",
          redirect_uris: [@redirect],
          token_endpoint_auth_method: "none"
        })
      )
      |> json_response(201)

    client_id = registered["client_id"]

    # 4. The person, signed in, sees the consent page and approves.
    request = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => @redirect,
      "state" => "s-123",
      "code_challenge" => ctx.challenge,
      "code_challenge_method" => "S256",
      "scope" => "write",
      "resource" => resource["resource"]
    }

    page = ctx.browser |> get(path(meta["authorization_endpoint"]), request) |> html_response(200)
    assert page =~ "Claude"

    back =
      ctx.browser
      |> post(
        path(meta["authorization_endpoint"]),
        Map.merge(request, %{"decision" => "approve", "scope" => scope})
      )
      |> redirected_to(302)

    assert String.starts_with?(back, @redirect <> "?")
    query = URI.decode_query(URI.parse(back).query)
    assert query["state"] == "s-123"
    assert query["iss"] == issuer

    # 5. The code for tokens, form-encoded as clients send it.
    tokens =
      anonymous()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(
        path(meta["token_endpoint"]),
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "code" => query["code"],
          "client_id" => client_id,
          "redirect_uri" => @redirect,
          "code_verifier" => ctx.verifier,
          "resource" => resource["resource"]
        })
      )
      |> json_response(200)

    assert tokens["token_type"] =~ ~r/bearer/i
    assert tokens["scope"] == scope
    Map.put(tokens, "client_id", client_id) |> Map.put("token_endpoint", meta["token_endpoint"])
  end

  test "from a bare /mcp address to reading and writing the board", ctx do
    tokens = connect_app(ctx, "write")
    access = tokens["access_token"]

    # 6. The MCP handshake and the tools, with the token just issued.
    init =
      access
      |> rpc("initialize", %{
        protocolVersion: "2025-11-25",
        capabilities: %{},
        clientInfo: %{name: "claude-ai", version: "1"}
      })
      |> json_response(200)

    assert init["result"]["protocolVersion"] == "2025-11-25"

    names =
      access
      |> rpc("tools/list", %{})
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Enum.map(& &1["name"])

    assert "whoami" in names and "create_card" in names

    me = call_tool(access, "whoami", %{})
    assert me["isError"] == false
    assert me["structuredContent"]["user"]["email"] == ctx.user.email

    made = call_tool(access, "create_card", %{board: ctx.board.code, title: "From claude.ai"})
    assert made["isError"] == false
    id = made["structuredContent"]["id"]

    read = call_tool(access, "get_card", %{card: id})
    assert read["structuredContent"]["title"] == "From claude.ai"

    # The connection is one ordinary API token, named for the client.
    row = Repo.get_by!(UserToken, user_id: ctx.user.id, label: "Claude", context: "api")
    assert row.oauth_client_id
    assert row.scope == "write"

    # 7. An hour later the access token has lapsed: refused, refreshed, used.
    Repo.update_all(
      from(t in UserToken, where: t.id == ^row.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    assert rpc(access, "tools/list", %{}).status == 401

    refreshed =
      anonymous()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(
        path(tokens["token_endpoint"]),
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => tokens["refresh_token"],
          "client_id" => tokens["client_id"]
        })
      )
      |> json_response(200)

    assert refreshed["access_token"] != access
    assert call_tool(refreshed["access_token"], "whoami", %{})["isError"] == false
  end

  test "a connection the person lowered to read can look but not write", ctx do
    access = connect_app(ctx, "read")["access_token"]

    assert call_tool(access, "list_boards", %{})["isError"] == false

    refused = call_tool(access, "create_card", %{board: ctx.board.code, title: "Sneaky"})
    assert refused["isError"] == true
    assert hd(refused["content"])["text"] =~ "read-only"

    assert call_tool(access, "list_cards", %{board: ctx.board.code})["structuredContent"]["cards"] ==
             []
  end
end
