defmodule SlipdockWeb.OAuth.DiscoveryTest do
  @moduledoc """
  OAuth discovery and dynamic client registration (#330): the documents a
  client reads first, and `POST /oauth/register` with the redirect-URI rules
  and rate limit that keep it from being a way to send codes anywhere.
  """
  # Sync: turns rate limiting on, and the counts are one table for the node
  # (RateLimit.reset/0 clears everybody's).
  use SlipdockWeb.ConnCase, async: false

  alias Slipdock.OAuth
  alias Slipdock.OAuth.Client

  @moduletag :anonymous

  setup do
    Slipdock.RateLimit.reset()
    :ok
  end

  defp register(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/oauth/register", Jason.encode!(params))
  end

  describe "metadata" do
    test "protected-resource metadata names /mcp and this server, at both addresses", %{
      conn: conn
    } do
      # The test connection reaches us as www.example.com.
      base = "http://www.example.com"

      for path <- [
            "/.well-known/oauth-protected-resource/mcp",
            "/.well-known/oauth-protected-resource"
          ] do
        doc = conn |> get(path) |> json_response(200)

        assert doc["resource"] == base <> "/mcp"
        assert doc["authorization_servers"] == [base]
        assert doc["scopes_supported"] == ["read", "write"]
        assert doc["bearer_methods_supported"] == ["header"]
      end
    end

    test "the address a 401 from /mcp points at is one that answers", %{conn: conn} do
      [challenge] =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", "{}")
        |> get_resp_header("www-authenticate")

      [_, url] = Regex.run(~r/resource_metadata="([^"]+)"/, challenge)

      assert %{"resource" => _} = conn |> get(URI.parse(url).path) |> json_response(200)
    end

    test "authorization-server metadata has what Claude's clients insist on", %{conn: conn} do
      # The test connection reaches us as www.example.com.
      base = "http://www.example.com"
      resp = get(conn, ~p"/.well-known/oauth-authorization-server")
      doc = json_response(resp, 200)

      # The issuer must equal the authorization server the resource names.
      assert doc["issuer"] == base
      assert doc["authorization_endpoint"] == base <> "/oauth/authorize"
      assert doc["token_endpoint"] == base <> "/oauth/token"
      assert doc["registration_endpoint"] == base <> "/oauth/register"
      assert doc["code_challenge_methods_supported"] == ["S256"]
      assert doc["token_endpoint_auth_methods_supported"] == ["none"]
      assert doc["response_types_supported"] == ["code"]
      assert doc["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert doc["authorization_response_iss_parameter_supported"] == true
      # Never admin: whoever starts an OAuth request is anonymous.
      refute "admin" in doc["scopes_supported"]
      # No CIMD yet (W-21 §6), so it must not be advertised.
      refute Map.has_key?(doc, "client_id_metadata_document_supported")
      assert get_resp_header(resp, "cache-control") == ["public, max-age=3600"]
    end

    test "addresses follow the name the client reached us by", %{conn: conn} do
      doc =
        %{conn | host: "slipdock.lan", port: 4000}
        |> get(~p"/.well-known/oauth-authorization-server")
        |> json_response(200)

      assert doc["issuer"] == "http://slipdock.lan:4000"
      assert doc["registration_endpoint"] == "http://slipdock.lan:4000/oauth/register"
    end
  end

  describe "registration" do
    test "claude.ai's registration succeeds and is stored", %{conn: conn} do
      resp =
        register(conn, %{
          client_name: "Claude",
          redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
          grant_types: ["authorization_code", "refresh_token"],
          token_endpoint_auth_method: "none"
        })

      body = json_response(resp, 201)

      assert "sdc_" <> _ = body["client_id"]
      assert body["client_name"] == "Claude"
      assert body["redirect_uris"] == ["https://claude.ai/api/mcp/auth_callback"]
      assert body["token_endpoint_auth_method"] == "none"
      assert is_integer(body["client_id_issued_at"])
      assert get_resp_header(resp, "cache-control") == ["no-store"]

      client = OAuth.get_client(body["client_id"])
      assert client.client_name == "Claude"
      assert client.registered_ip
    end

    test "loopback http is allowed, for Claude Code and other native apps", %{conn: conn} do
      uris = [
        "http://localhost:53682/callback",
        "http://127.0.0.1/callback",
        "http://[::1]:8080/cb"
      ]

      body = conn |> register(%{redirect_uris: uris}) |> json_response(201)
      assert body["redirect_uris"] == uris
      # No name given: none stored, rather than a made-up one.
      assert body["client_name"] == nil
    end

    test "each registration is a new client", %{conn: conn} do
      params = %{
        client_name: "Claude",
        redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]
      }

      a = conn |> register(params) |> json_response(201)
      b = conn |> register(params) |> json_response(201)

      refute a["client_id"] == b["client_id"]
    end

    test "what the client claims about secrets is overruled: it is public", %{conn: conn} do
      body =
        conn
        |> register(%{
          redirect_uris: ["https://example.com/cb"],
          token_endpoint_auth_method: "client_secret_basic",
          grant_types: ["client_credentials"]
        })
        |> json_response(201)

      assert body["token_endpoint_auth_method"] == "none"
      assert body["grant_types"] == ["authorization_code", "refresh_token"]
      refute Map.has_key?(body, "client_secret")
    end

    test "a hostile name is cleaned before anybody is shown it", %{conn: conn} do
      body =
        conn
        |> register(%{
          client_name: "  Evil\nApp\t" <> String.duplicate("x", 300),
          redirect_uris: ["https://example.com/cb"]
        })
        |> json_response(201)

      assert body["client_name"] =~ ~r/^Evil App x+$/
      assert String.length(body["client_name"]) == 100
    end

    for {why, uri} <- [
          {"plain http off loopback", "http://example.com/cb"},
          {"http to a LAN name", "http://slipdock.lan/cb"},
          {"a custom scheme", "myapp://callback"},
          {"javascript:", "javascript:alert(1)"},
          {"a fragment", "https://example.com/cb#frag"},
          {"user info", "https://user@example.com/cb"},
          {"no host", "https:///cb"},
          {"relative", "/callback"},
          {"localhost as a subdomain", "http://localhost.evil.com/cb"}
        ] do
      test "refuses #{why}", %{conn: conn} do
        body =
          conn
          |> register(%{redirect_uris: ["https://example.com/ok", unquote(uri)]})
          |> json_response(400)

        assert body["error"] == "invalid_redirect_uri"
        assert body["error_description"] =~ "not an allowed redirect URI"
        assert Slipdock.Repo.aggregate(Client, :count) == 0
      end
    end

    test "refuses a missing, empty or malformed redirect_uris", %{conn: conn} do
      for params <- [
            %{client_name: "x"},
            %{redirect_uris: []},
            %{redirect_uris: "https://example.com/cb"},
            %{redirect_uris: [42]}
          ] do
        assert %{"error" => "invalid_redirect_uri"} =
                 conn |> register(params) |> json_response(400)
      end

      assert Slipdock.Repo.aggregate(Client, :count) == 0
    end

    test "refuses too many redirect URIs", %{conn: conn} do
      uris = for n <- 1..11, do: "https://example.com/cb#{n}"

      assert %{"error" => "invalid_redirect_uri"} =
               conn |> register(%{redirect_uris: uris}) |> json_response(400)
    end

    test "refuses a client_name that is not a string", %{conn: conn} do
      assert %{"error" => "invalid_client_metadata"} =
               conn
               |> register(%{client_name: %{"x" => 1}, redirect_uris: ["https://example.com/cb"]})
               |> json_response(400)
    end

    test "is rate limited per address", %{conn: conn} do
      previous = Application.get_env(:slipdock, :rate_limit)
      Application.put_env(:slipdock, :rate_limit, enabled: true)
      Slipdock.RateLimit.reset()

      on_exit(fn ->
        Application.put_env(:slipdock, :rate_limit, previous)
        Slipdock.RateLimit.reset()
      end)

      params = %{redirect_uris: ["https://example.com/cb"]}
      for _ <- 1..30, do: conn |> register(params) |> json_response(201)

      resp = register(conn, params)
      assert %{"error" => "slow_down"} = json_response(resp, 429)
      assert [retry] = get_resp_header(resp, "retry-after")
      assert String.to_integer(retry) in 1..60
      assert Slipdock.Repo.aggregate(Client, :count) == 30
    end
  end
end
