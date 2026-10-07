defmodule SlipdockWeb.OAuth.AuthorizationTest do
  @moduledoc """
  The authorize, consent and token endpoints (#331), end to end as a client
  would drive them, and the things they exist to refuse: a missing or wrong
  PKCE verifier, a code used twice or late, a redirect URI that was never
  registered, a refusal, a refresh token used twice, and a revoked token.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query

  alias Slipdock.Accounts
  alias Slipdock.Accounts.UserToken
  alias Slipdock.OAuth
  alias Slipdock.OAuth.Code
  alias Slipdock.Repo

  @base "http://www.example.com"
  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup %{conn: conn, user: user} do
    {:ok, client} =
      OAuth.register_client(%{
        client_name: "Claude",
        redirect_uris: [@redirect, "http://localhost:3118/callback"]
      })

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    # Signed in for the consent page, and with no bearer token, as a browser.
    browser = conn |> Plug.Conn.delete_req_header("authorization")
    anonymous = Phoenix.ConnTest.build_conn()

    {:ok,
     browser: browser,
     anonymous: anonymous,
     user: user,
     client: client,
     verifier: verifier,
     challenge: challenge}
  end

  defp authorize_params(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => ctx.client.client_id,
        "redirect_uri" => @redirect,
        "state" => "xyz-state",
        "code_challenge" => ctx.challenge,
        "code_challenge_method" => "S256",
        "scope" => "write",
        "resource" => @base <> "/mcp"
      },
      overrides
    )
  end

  # Approve on the consent page; returns the query the app is sent back with.
  defp approve(ctx, overrides \\ %{}, extra \\ %{}) do
    params =
      authorize_params(ctx, overrides)
      |> Map.merge(%{"decision" => "approve"})
      |> Map.merge(extra)

    conn = post(ctx.browser, ~p"/oauth/authorize", params)
    location = redirected_to(conn, 302)
    {location, URI.decode_query(URI.parse(location).query || "")}
  end

  defp token(ctx, params) do
    post(ctx.anonymous, ~p"/oauth/token", params)
  end

  defp exchange(ctx, code, overrides \\ %{}) do
    token(
      ctx,
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => ctx.client.client_id,
          "redirect_uri" => @redirect,
          "code_verifier" => ctx.verifier,
          "resource" => @base <> "/mcp"
        },
        overrides
      )
    )
  end

  defp refresh(ctx, refresh_token) do
    token(ctx, %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => ctx.client.client_id
    })
  end

  defp mcp(conn, access_token) do
    conn
    |> put_req_header("authorization", "Bearer " <> access_token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
  end

  describe "the happy path" do
    test "consent, code, token, use it on /mcp, and it is an ordinary API token", ctx do
      page = ctx.browser |> get(~p"/oauth/authorize", authorize_params(ctx)) |> html_response(200)
      assert page =~ "Claude"
      assert page =~ "claude.ai"
      assert page =~ ~s(name="decision" value="approve")
      # The form posts here, with the request carried in hidden fields.
      assert page =~ ~s(action="/oauth/authorize")
      assert page =~ ctx.challenge

      {location, query} = approve(ctx)
      assert String.starts_with?(location, @redirect <> "?")
      assert query["state"] == "xyz-state"
      assert query["iss"] == @base
      assert code = query["code"]

      resp = exchange(ctx, code)
      body = json_response(resp, 200)
      assert get_resp_header(resp, "cache-control") == ["no-store"]
      assert body["token_type"] == "Bearer"
      assert body["expires_in"] == 3600
      assert body["scope"] == "write"
      assert body["refresh_token"]

      assert %{"result" => %{}} = ctx.anonymous |> mcp(body["access_token"]) |> json_response(200)

      # One row under Account → API tokens, named after the app.
      [row] = Accounts.list_api_tokens(ctx.user) |> Enum.filter(&(&1.label == "Claude"))
      assert row.scope == "write"
      assert row.scope_boards == []
      assert row.oauth_client_id == ctx.client.id
      assert DateTime.diff(row.expires_at, DateTime.utc_now()) in 3590..3600
      assert DateTime.diff(row.refresh_expires_at, DateTime.utc_now(), :day) in 89..90
    end

    test "the consent page lets the app's origin receive the form's redirect", ctx do
      resp = get(ctx.browser, ~p"/oauth/authorize", authorize_params(ctx))
      [csp] = get_resp_header(resp, "content-security-policy")
      assert csp =~ "form-action 'self' https://claude.ai;"

      resp =
        get(
          ctx.browser,
          ~p"/oauth/authorize",
          authorize_params(ctx, %{"redirect_uri" => "http://localhost:53682/callback"})
        )

      [csp] = get_resp_header(resp, "content-security-policy")
      assert csp =~ "form-action 'self' http://localhost:53682;"
      assert html_response(resp, 200) =~ "an app on this computer"
    end

    test "a loopback app gets its code on the port it is listening on today", ctx do
      {location, query} = approve(ctx, %{"redirect_uri" => "http://localhost:53682/callback"})
      assert String.starts_with?(location, "http://localhost:53682/callback?")

      assert %{"access_token" => _} =
               ctx
               |> exchange(query["code"], %{"redirect_uri" => "http://localhost:53682/callback"})
               |> json_response(200)
    end

    test "the person can lower write to read, and nobody can raise read to write", ctx do
      {_, query} = approve(ctx, %{}, %{"granted_scope" => "read"})
      assert %{"scope" => "read"} = ctx |> exchange(query["code"]) |> json_response(200)

      {_, query} = approve(ctx, %{"scope" => "read"}, %{"granted_scope" => "write"})
      assert %{"scope" => "read"} = ctx |> exchange(query["code"]) |> json_response(200)
    end

    test "no scope asked for is write; admin is never granted", ctx do
      {_, query} = approve(ctx, %{"scope" => nil})
      assert %{"scope" => "write"} = ctx |> exchange(query["code"]) |> json_response(200)

      {_, query} = approve(ctx, %{"scope" => "admin"})
      assert %{"scope" => "read"} = ctx |> exchange(query["code"]) |> json_response(200)
    end
  end

  describe "the consent page" do
    test "a signed-out visitor is sent to sign in and brought back", ctx do
      conn = get(ctx.anonymous, ~p"/oauth/authorize", authorize_params(ctx))
      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, :user_return_to) =~ "/oauth/authorize?"
      assert get_session(conn, :user_return_to) =~ "client_id="
    end

    test "a signed-out POST approves nothing", ctx do
      conn =
        post(
          ctx.anonymous,
          ~p"/oauth/authorize",
          Map.put(authorize_params(ctx), "decision", "approve")
        )

      assert redirected_to(conn) == ~p"/login"
      assert Repo.aggregate(Code, :count) == 0
    end

    test "the GET only asks: it never issues a code", ctx do
      ctx.browser
      |> get(~p"/oauth/authorize", Map.put(authorize_params(ctx), "decision", "approve"))
      |> html_response(200)

      assert Repo.aggregate(Code, :count) == 0
    end

    test "refusing sends access_denied back, with the state", ctx do
      conn =
        post(
          ctx.browser,
          ~p"/oauth/authorize",
          Map.put(authorize_params(ctx), "decision", "deny")
        )

      query = conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query["error"] == "access_denied"
      assert query["state"] == "xyz-state"
      refute query["code"]
      assert Repo.aggregate(Code, :count) == 0
    end

    test "an unknown client is told here, and nobody is redirected", ctx do
      body =
        ctx.browser
        |> get(~p"/oauth/authorize", authorize_params(ctx, %{"client_id" => "sdc_nope"}))
        |> html_response(400)

      assert body =~ "know the app that sent you here"
    end

    test "an unregistered redirect URI is told here, never followed", ctx do
      for uri <- ["https://evil.example/cb", "https://claude.ai/api/mcp/auth_callback/x", nil] do
        conn =
          get(ctx.browser, ~p"/oauth/authorize", authorize_params(ctx, %{"redirect_uri" => uri}))

        assert html_response(conn, 400) =~ "never registered"
      end

      conn =
        post(
          ctx.browser,
          ~p"/oauth/authorize",
          authorize_params(ctx, %{
            "redirect_uri" => "https://evil.example/cb",
            "decision" => "approve"
          })
        )

      assert html_response(conn, 400)
      assert Repo.aggregate(Code, :count) == 0
    end

    test "with one registered redirect URI it may be left out", ctx do
      {:ok, single} = OAuth.register_client(%{client_name: "One", redirect_uris: [@redirect]})

      {location, query} = approve(ctx, %{"client_id" => single.client_id, "redirect_uri" => nil})
      assert String.starts_with?(location, @redirect)

      assert %{"access_token" => _} =
               ctx
               |> exchange(query["code"], %{"client_id" => single.client_id})
               |> json_response(200)
    end

    for {why, overrides, error} <- [
          {"without PKCE", %{"code_challenge" => nil}, "invalid_request"},
          {"with plain PKCE", %{"code_challenge_method" => "plain"}, "invalid_request"},
          {"with a malformed challenge", %{"code_challenge" => "short"}, "invalid_request"},
          {"for a token response", %{"response_type" => "token"}, "unsupported_response_type"},
          {"for some other resource", %{"resource" => "https://elsewhere.example/mcp"},
           "invalid_target"}
        ] do
      test "a request #{why} goes back to the app as #{error}", ctx do
        conn =
          get(
            ctx.browser,
            ~p"/oauth/authorize",
            authorize_params(ctx, unquote(Macro.escape(overrides)))
          )

        location = redirected_to(conn, 302)
        assert String.starts_with?(location, @redirect)
        query = URI.decode_query(URI.parse(location).query)
        assert query["error"] == unquote(error)
        assert query["state"] == "xyz-state"
        assert query["iss"] == @base
      end
    end
  end

  describe "the token endpoint" do
    test "a wrong or missing verifier gets nothing, and spends the code", ctx do
      {_, query} = approve(ctx)

      assert %{"error" => "invalid_grant"} =
               ctx
               |> exchange(query["code"], %{"code_verifier" => String.duplicate("a", 43)})
               |> json_response(400)

      # The right verifier is too late now: the code went on the first try.
      assert %{"error" => "invalid_grant"} = ctx |> exchange(query["code"]) |> json_response(400)

      {_, query} = approve(ctx)

      assert %{"error" => "invalid_grant"} =
               ctx |> exchange(query["code"], %{"code_verifier" => nil}) |> json_response(400)
    end

    test "a code used twice fails, and takes back the token it bought", ctx do
      {_, query} = approve(ctx)
      %{"access_token" => access} = ctx |> exchange(query["code"]) |> json_response(200)
      assert ctx.anonymous |> mcp(access) |> json_response(200)

      assert %{"error" => "invalid_grant", "error_description" => description} =
               ctx |> exchange(query["code"]) |> json_response(400)

      assert description =~ "already been used"
      assert ctx.anonymous |> mcp(access) |> response(401)
    end

    test "an expired code fails", ctx do
      {_, query} = approve(ctx)

      Repo.update_all(Code,
        set: [expires_at: DateTime.utc_now(:second) |> DateTime.add(-1, :second)]
      )

      assert %{"error" => "invalid_grant", "error_description" => "the code has expired"} =
               ctx |> exchange(query["code"]) |> json_response(400)
    end

    test "a redirect URI other than the code's fails", ctx do
      {_, query} = approve(ctx)

      assert %{"error" => "invalid_grant"} =
               ctx
               |> exchange(query["code"], %{"redirect_uri" => "http://localhost:3118/callback"})
               |> json_response(400)
    end

    test "a code issued to another client fails", ctx do
      {:ok, other} = OAuth.register_client(%{redirect_uris: [@redirect]})
      {_, query} = approve(ctx)

      assert %{"error" => "invalid_grant"} =
               ctx
               |> exchange(query["code"], %{"client_id" => other.client_id})
               |> json_response(400)
    end

    test "an unknown client is a 401; a bad resource is invalid_target", ctx do
      {_, query} = approve(ctx)

      assert %{"error" => "invalid_client"} =
               ctx |> exchange(query["code"], %{"client_id" => "sdc_nope"}) |> json_response(401)

      {_, query} = approve(ctx)

      assert %{"error" => "invalid_target"} =
               ctx
               |> exchange(query["code"], %{"resource" => "https://elsewhere.example/mcp"})
               |> json_response(400)
    end

    test "garbage, a missing grant type and an unsupported one", ctx do
      assert %{"error" => "invalid_grant"} =
               ctx |> exchange("not base64!!") |> json_response(400)

      assert %{"error" => "invalid_grant"} =
               ctx |> exchange(Base.url_encode64("unknown", padding: false)) |> json_response(400)

      assert %{"error" => "invalid_request"} = ctx |> token(%{}) |> json_response(400)

      assert %{"error" => "unsupported_grant_type"} =
               ctx |> token(%{"grant_type" => "client_credentials"}) |> json_response(400)
    end

    test "a disabled account gets no token", ctx do
      {_, query} = approve(ctx)
      {:ok, _} = Accounts.disable(ctx.user)

      assert %{"error" => "invalid_grant"} = ctx |> exchange(query["code"]) |> json_response(400)
    end
  end

  describe "refresh" do
    setup ctx do
      {_, query} = approve(ctx)
      {:ok, tokens: ctx |> exchange(query["code"]) |> json_response(200)}
    end

    test "rotates both tokens on the same row", ctx do
      %{"access_token" => old_access, "refresh_token" => old_refresh} = ctx.tokens
      [row] = Repo.all(from(t in UserToken, where: t.oauth_client_id == ^ctx.client.id))

      body = ctx |> refresh(old_refresh) |> json_response(200)
      assert body["access_token"] != old_access
      assert body["refresh_token"] != old_refresh
      assert body["scope"] == "write"
      assert body["expires_in"] == 3600

      # Same connection, same row.
      assert [%{id: id}] =
               Repo.all(from(t in UserToken, where: t.oauth_client_id == ^ctx.client.id))

      assert id == row.id

      assert ctx.anonymous |> mcp(body["access_token"]) |> json_response(200)
      assert ctx.anonymous |> mcp(old_access) |> response(401)

      # The old refresh token is spent.
      assert %{"error" => "invalid_grant"} = ctx |> refresh(old_refresh) |> json_response(400)
      # And the new one works, once.
      assert %{"refresh_token" => _} = ctx |> refresh(body["refresh_token"]) |> json_response(200)
    end

    test "an expired access token is refused until it is refreshed", ctx do
      Repo.update_all(from(t in UserToken, where: t.oauth_client_id == ^ctx.client.id),
        set: [expires_at: DateTime.utc_now(:second) |> DateTime.add(-1, :second)]
      )

      assert ctx.anonymous |> mcp(ctx.tokens["access_token"]) |> response(401)

      %{"access_token" => fresh} =
        ctx |> refresh(ctx.tokens["refresh_token"]) |> json_response(200)

      assert ctx.anonymous |> mcp(fresh) |> json_response(200)
    end

    test "an expired refresh token, or one shown by another client, fails", ctx do
      {:ok, other} = OAuth.register_client(%{redirect_uris: [@redirect]})

      assert %{"error" => "invalid_grant"} =
               ctx
               |> token(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => ctx.tokens["refresh_token"],
                 "client_id" => other.client_id
               })
               |> json_response(400)

      Repo.update_all(from(t in UserToken, where: t.oauth_client_id == ^ctx.client.id),
        set: [refresh_expires_at: DateTime.utc_now(:second) |> DateTime.add(-1, :second)]
      )

      assert %{"error" => "invalid_grant"} =
               ctx |> refresh(ctx.tokens["refresh_token"]) |> json_response(400)
    end

    test "revoking the token under Account → API tokens ends both halves", ctx do
      [row] = Repo.all(from(t in UserToken, where: t.oauth_client_id == ^ctx.client.id))
      :ok = Accounts.delete_api_token(ctx.user, row.id)

      assert ctx.anonymous |> mcp(ctx.tokens["access_token"]) |> response(401)

      assert %{"error" => "invalid_grant"} =
               ctx |> refresh(ctx.tokens["refresh_token"]) |> json_response(400)
    end

    test "a disabled account cannot refresh", ctx do
      {:ok, _} = Accounts.disable(ctx.user)

      assert %{"error" => "invalid_grant"} =
               ctx |> refresh(ctx.tokens["refresh_token"]) |> json_response(400)
    end
  end

  describe "housekeeping" do
    test "clients that never got a token are purged after a day; others stay", ctx do
      {:ok, abandoned} = OAuth.register_client(%{redirect_uris: [@redirect]})
      {_, query} = approve(ctx)
      ctx |> exchange(query["code"]) |> json_response(200)

      old = DateTime.utc_now(:second) |> DateTime.add(-25, :hour)
      Repo.update_all(Slipdock.OAuth.Client, set: [inserted_at: old])

      assert OAuth.purge_unused_clients() == 1
      refute OAuth.get_client(abandoned.client_id)
      assert OAuth.get_client(ctx.client.client_id)
    end
  end
end
