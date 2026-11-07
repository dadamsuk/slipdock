defmodule SlipdockWeb.UserAuthBearerTest do
  # The one place a request's bearer token is read (#1931): the API and MCP
  # plugs look the user up through `api_user_from_bearer/1`, and the runner
  # and deploy plugs take the bare token from `bearer_token/1`.
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Accounts
  alias SlipdockWeb.UserAuth

  defp with_auth(value), do: put_req_header(build_conn(), "authorization", value)

  describe "bearer_token/1" do
    test "the token, trimmed" do
      assert UserAuth.bearer_token(with_auth("Bearer abc")) == "abc"
      assert UserAuth.bearer_token(with_auth("Bearer abc ")) == "abc"
      assert UserAuth.bearer_token(with_auth("Bearer   abc\t")) == "abc"
    end

    test "nil with no header, another scheme, or two headers" do
      assert UserAuth.bearer_token(build_conn()) == nil
      assert UserAuth.bearer_token(with_auth("Basic dXNlcjpwYXNz")) == nil
      assert UserAuth.bearer_token(with_auth("Bearerabc")) == nil

      two =
        build_conn()
        |> Map.update!(:req_headers, &[{"authorization", "Bearer a"} | &1])
        |> Map.update!(:req_headers, &[{"authorization", "Bearer b"} | &1])

      assert UserAuth.bearer_token(two) == nil
    end
  end

  describe "api_user_from_bearer/1" do
    test "the user and token for a live API token, spaces and all", %{user: user} do
      {token, _} = Accounts.create_api_token(user, "agent")

      assert {found, api_token} = UserAuth.api_user_from_bearer(with_auth("Bearer " <> token))
      assert found.id == user.id
      assert api_token.user_id == user.id

      assert {%{id: id}, _} = UserAuth.api_user_from_bearer(with_auth("Bearer #{token}  "))
      assert id == user.id
    end

    test "nil with no token, a wrong one or a revoked one", %{user: user} do
      assert UserAuth.api_user_from_bearer(build_conn()) == nil
      assert UserAuth.api_user_from_bearer(with_auth("Bearer ")) == nil
      assert UserAuth.api_user_from_bearer(with_auth("Bearer sdk_nope")) == nil

      {token, record} = Accounts.create_api_token(user, "gone")
      Slipdock.Repo.delete!(record)
      assert UserAuth.api_user_from_bearer(with_auth("Bearer " <> token)) == nil
    end
  end

  describe "the API plugs" do
    test "fetch_api_user takes a token with a trailing space and 401s without one", %{
      user: user
    } do
      {token, _} = Accounts.create_api_token(user, "agent")

      conn = UserAuth.fetch_api_user(with_auth("Bearer #{token} "), [])
      refute conn.halted
      assert conn.assigns.current_user.id == user.id

      conn = UserAuth.fetch_api_user(build_conn(), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "maybe_fetch_api_user carries on with nobody when the token is bad" do
      conn = UserAuth.maybe_fetch_api_user(with_auth("Bearer sdk_nope"), [])
      refute conn.halted
      assert conn.assigns.current_user == nil
      assert conn.assigns.api_token == nil
    end
  end
end
