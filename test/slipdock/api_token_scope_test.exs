defmodule Slipdock.ApiTokenScopeTest do
  @moduledoc """
  Scope and expiry on API tokens. Scope is *recorded* here and enforced in
  `Slipdock.Access` (#163); expiry is enforced here, because an expiry the
  server does not honour is a promise the UI makes and breaks.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
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

  describe "the last-use stamp (#2798)" do
    test "two quick requests make one write", ctx do
      {plain, _} = Accounts.create_api_token(ctx.user, "cli")

      assert token_writes(fn -> Accounts.get_api_token(plain, ip: "203.0.113.7") end) == 1
      assert token_writes(fn -> Accounts.get_api_token(plain, ip: "203.0.113.8") end) == 0

      # The second request still authenticated; it just left the stamp alone.
      [stored] = Accounts.list_api_tokens(ctx.user)
      assert stored.last_used_ip == "203.0.113.7"
    end

    test "a stamp an interval old is written again, with the new IP", ctx do
      {plain, token} = Accounts.create_api_token(ctx.user, "cli")
      Accounts.get_api_token(plain, ip: "203.0.113.7")

      old = seconds_from_now(-Accounts.api_token_touch_interval())
      backdate(token, old)

      assert token_writes(fn -> Accounts.get_api_token(plain, ip: "203.0.113.8") end) == 1
      [stored] = Accounts.list_api_tokens(ctx.user)
      assert stored.last_used_ip == "203.0.113.8"
      assert DateTime.compare(stored.last_used_at, old) == :gt
    end

    test "a stamp just inside the interval is left alone", ctx do
      {plain, token} = Accounts.create_api_token(ctx.user, "cli")
      Accounts.get_api_token(plain, ip: "203.0.113.7")

      recent = seconds_from_now(-(Accounts.api_token_touch_interval() - 5))
      backdate(token, recent)

      assert token_writes(fn -> Accounts.get_api_token(plain, ip: "203.0.113.8") end) == 0
      [stored] = Accounts.list_api_tokens(ctx.user)
      assert stored.last_used_ip == "203.0.113.7"
      assert stored.last_used_at == recent
    end

    test "a request with no IP stamps the time and keeps the last IP", ctx do
      {plain, token} = Accounts.create_api_token(ctx.user, "cli")
      Accounts.get_api_token(plain, ip: "203.0.113.7")
      backdate(token, seconds_from_now(-Accounts.api_token_touch_interval() - 1))

      assert token_writes(fn -> Accounts.get_api_token(plain) end) == 1
      [stored] = Accounts.list_api_tokens(ctx.user)
      assert stored.last_used_ip == "203.0.113.7"
    end

    test "a request racing past the check doesn't overwrite a fresher stamp", ctx do
      {plain, token} = Accounts.create_api_token(ctx.user, "cli")
      Accounts.get_api_token(plain, ip: "203.0.113.7")

      # What this request read: a stamp an interval old, so it will write.
      backdate(token, seconds_from_now(-Accounts.api_token_touch_interval() - 1))
      [read] = Accounts.list_api_tokens(ctx.user)

      # Between its read and its write, another request stamps the row.
      fresh = seconds_from_now(-1)

      Slipdock.Repo.update_all(from(t in UserToken, where: t.id == ^token.id),
        set: [last_used_at: fresh, last_used_ip: "203.0.113.9"]
      )

      Accounts.touch_api_token(read, "203.0.113.8")

      [stored] = Accounts.list_api_tokens(ctx.user)
      assert stored.last_used_ip == "203.0.113.9"
      assert stored.last_used_at == fresh
    end

    test "a request that fails to authenticate writes nothing", ctx do
      {plain, _} = Accounts.create_api_token(ctx.user, "stale", expires_at: days_from_now(-1))
      assert token_writes(fn -> refute Accounts.get_api_token(plain, ip: "203.0.113.7") end) == 0
    end
  end

  defp backdate(token, at) do
    Slipdock.Repo.update_all(from(t in UserToken, where: t.id == ^token.id),
      set: [last_used_at: at]
    )
  end

  # UPDATEs on the tokens table made by this test's process while `fun` runs.
  defp token_writes(fun) do
    ref = make_ref()
    me = self()
    handler = "token-writes-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:slipdock, :repo, :query],
      fn _event, _measurements, meta, _ ->
        if self() == me and meta.query =~ ~r/^UPDATE\b/i and meta.source == "users_tokens",
          do: send(me, {ref, :write})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    count(ref, 0)
  end

  defp count(ref, n) do
    receive do
      {^ref, :write} -> count(ref, n + 1)
    after
      0 -> n
    end
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
