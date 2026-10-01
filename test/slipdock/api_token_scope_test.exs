defmodule Slipdock.ApiTokenScopeTest do
  @moduledoc """
  Scope and expiry on API tokens. Scope is *recorded* here and enforced in
  `Slipdock.Access` (#163); expiry is enforced here, because an expiry the
  server does not honour is a promise the UI makes and breaks.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Accounts
  alias Slipdock.Accounts.UserToken

  setup do
    %{user: user_fixture("owner@example.com")}
  end

  test "a token defaults to read/write, the whole account, and no expiry", ctx do
    {_plain, token} = Accounts.create_api_token(ctx.user, "laptop")

    assert token.scope == "write"
    assert token.scope_boards == []
    assert is_nil(token.expires_at)
    refute UserToken.expired?(token)
  end

  test "scope and board list are recorded as given", ctx do
    {_plain, token} =
      Accounts.create_api_token(ctx.user, "reader", scope: "read", scope_boards: [1, 2])

    assert token.scope == "read"
    assert token.scope_boards == [1, 2]
  end

  test "an unknown scope falls back to write rather than being stored", ctx do
    {_plain, token} = Accounts.create_api_token(ctx.user, "odd", scope: "sideways")
    assert token.scope == "write"
  end

  test "an unexpired token still authenticates", ctx do
    {plain, _} = Accounts.create_api_token(ctx.user, "fresh", expires_at: days_from_now(30))
    assert %Accounts.User{id: id} = Accounts.get_user_by_api_token(plain)
    assert id == ctx.user.id
  end

  test "an expired token does not authenticate", ctx do
    {plain, _} = Accounts.create_api_token(ctx.user, "stale", expires_at: days_from_now(-1))
    refute Accounts.get_user_by_api_token(plain)
  end

  test "expiry is enforced at the boundary, not a day either side", ctx do
    {past, _} = Accounts.create_api_token(ctx.user, "a", expires_at: seconds_from_now(-1))
    {future, _} = Accounts.create_api_token(ctx.user, "b", expires_at: seconds_from_now(60))

    refute Accounts.get_user_by_api_token(past)
    assert Accounts.get_user_by_api_token(future)
  end

  test "using a token records when and where from", ctx do
    {plain, token} = Accounts.create_api_token(ctx.user, "cli")
    assert is_nil(token.last_used_at)

    Accounts.get_api_token(plain, ip: "203.0.113.7")

    [stored] = Accounts.list_api_tokens(ctx.user)
    assert stored.last_used_ip == "203.0.113.7"
    assert stored.last_used_at
  end

  test "expiry_in_days accepts days, strings and nothing" do
    assert is_nil(Accounts.expiry_in_days(nil))
    assert is_nil(Accounts.expiry_in_days(""))
    assert is_nil(Accounts.expiry_in_days("not a number"))
    assert is_nil(Accounts.expiry_in_days(0))

    assert %DateTime{} = at = Accounts.expiry_in_days("90")
    assert DateTime.diff(at, DateTime.utc_now(), :day) in 89..90
  end

  test "expired?/1 is false for a token that never expires", ctx do
    {_plain, token} = Accounts.create_api_token(ctx.user, "forever")
    refute UserToken.expired?(token)
  end

  defp days_from_now(n), do: DateTime.utc_now(:second) |> DateTime.add(n, :day)
  defp seconds_from_now(n), do: DateTime.utc_now(:second) |> DateTime.add(n, :second)
end
