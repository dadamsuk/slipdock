defmodule SlipdockWeb.OAuth.MetadataController do
  @moduledoc """
  The two discovery documents an OAuth client reads before anything else.

    * Protected-resource metadata (RFC 9728) says which authorization server
      issues tokens for `/mcp`. A 401 from `/mcp` points here
      (`SlipdockWeb.MCP.Plug.challenge/1`). Clients try the path-suffixed
      address first and then the root one, so both answer the same.
    * Authorization-server metadata (RFC 8414) says where to register, where
      to send the person, and where to collect a token.

  Every address in them is built from the URL the client reached us by
  (`SlipdockWeb.BaseURL`), because clients compare `resource` and `issuer`
  with what they typed, character for character.
  """
  use SlipdockWeb, :controller

  @scopes ~w(read write)

  @doc "GET /.well-known/oauth-protected-resource[/mcp]"
  def protected_resource(conn, _params) do
    base = SlipdockWeb.BaseURL.from_conn(conn)

    conn
    |> cacheable()
    |> json(%{
      resource: base <> "/mcp",
      authorization_servers: [base],
      scopes_supported: @scopes,
      bearer_methods_supported: ["header"],
      resource_name: "Slipdock",
      resource_documentation: base <> "/api/guide"
    })
  end

  @doc "GET /.well-known/oauth-authorization-server"
  def authorization_server(conn, _params) do
    base = SlipdockWeb.BaseURL.from_conn(conn)

    conn
    |> cacheable()
    |> json(%{
      issuer: base,
      authorization_endpoint: base <> "/oauth/authorize",
      token_endpoint: base <> "/oauth/token",
      registration_endpoint: base <> "/oauth/register",
      scopes_supported: @scopes,
      response_types_supported: ["code"],
      response_modes_supported: ["query"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      # Public clients only: an app on somebody's machine cannot keep a secret.
      token_endpoint_auth_methods_supported: ["none"],
      # Clients must refuse a server that does not list this (W-21 §2).
      code_challenge_methods_supported: ["S256"],
      authorization_response_iss_parameter_supported: true,
      service_documentation: base <> "/api/guide"
    })
  end

  defp cacheable(conn), do: put_resp_header(conn, "cache-control", "public, max-age=3600")
end
