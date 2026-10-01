defmodule Slipdock.SignupsTest do
  @moduledoc """
  Who is allowed an account, and the counters that stop the sign-in form being
  used as a mailer. Both are off or open in the test environment by default
  (every other test signs in whoever it likes), so these turn them on.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, RateLimit}

  defp signups(opts) do
    previous = Application.get_env(:slipdock, :signups)
    Application.put_env(:slipdock, :signups, opts)
    on_exit(fn -> Application.put_env(:slipdock, :signups, previous) end)
  end

  describe "signup_allowed?/1 with sign-up closed" do
    setup do
      signups(open: false, allow: [])
      :ok
    end

    test "the first address claims an empty instance" do
      assert Accounts.count_users() == 0
      assert Accounts.signup_allowed?("first@example.com")
    end

    test "once somebody is here, a stranger is not" do
      user_fixture("owner@example.com")
      refute Accounts.signup_allowed?("stranger@example.com")
      # ...but the person who is already here always can.
      assert Accounts.signup_allowed?("owner@example.com")
      assert Accounts.signup_allowed?("  OWNER@Example.com  ")
    end

    test "a blank address is not an address" do
      user_fixture("owner@example.com")
      refute Accounts.signup_allowed?("")
      refute Accounts.signup_allowed?(nil)
    end

    test "no link is sent to an address that may not sign up, and it is not created" do
      user_fixture("owner@example.com")

      assert {:error, :not_allowed} =
               Accounts.deliver_magic_link("stranger@example.com", & &1)

      assert Accounts.get_user_by_email("stranger@example.com") == nil
      assert Accounts.count_users() == 1
    end

    test "agentic login obeys the same gate, so it is not a way round it" do
      user_fixture("owner@example.com")
      assert {:error, :not_allowed} = Accounts.write_agentic_login("stranger@example.com", & &1)
    end
  end

  describe "signup_allowed?/1 with an allowlist" do
    test "an address on the list, or anyone at a listed domain" do
      user_fixture("owner@example.com")
      signups(open: false, allow: ["friend@elsewhere.com", "@work.example", "Other.Example"])

      assert Accounts.signup_allowed?("friend@elsewhere.com")
      assert Accounts.signup_allowed?("anyone@work.example")
      assert Accounts.signup_allowed?("ANYONE@Other.Example")
      refute Accounts.signup_allowed?("nobody@elsewhere.com")
    end

    test "a link does go to an allowed stranger, and makes their account" do
      user_fixture("owner@example.com")
      signups(open: false, allow: ["@work.example"])

      assert {:ok, _} = Accounts.deliver_magic_link("new@work.example", &"/login/#{&1}")
      assert Accounts.get_user_by_email("new@work.example")
    end
  end

  describe "signup_allowed?/1 with sign-up open" do
    test "anybody can, which is the old behaviour" do
      user_fixture("owner@example.com")
      signups(open: true, allow: [])
      assert Accounts.signup_allowed?("stranger@example.com")
      assert Accounts.signups_open?()
    end
  end

  describe "Slipdock.RateLimit" do
    setup do
      previous = Application.get_env(:slipdock, :rate_limit)
      Application.put_env(:slipdock, :rate_limit, enabled: true)
      RateLimit.reset()

      on_exit(fn ->
        Application.put_env(:slipdock, :rate_limit, previous)
        RateLimit.reset()
      end)

      %{key: "test:#{System.unique_integer([:positive])}"}
    end

    test "allows up to the limit and then refuses, saying when to come back", ctx do
      window = :timer.hours(1)
      for _ <- 1..3, do: assert(:ok = RateLimit.hit(ctx.key, 3, window))

      assert {:error, seconds} = RateLimit.hit(ctx.key, 3, window)
      assert seconds > 0
      assert seconds <= 3601
    end

    test "counts each key separately", ctx do
      assert :ok = RateLimit.hit(ctx.key, 1, :timer.hours(1))
      assert {:error, _} = RateLimit.hit(ctx.key, 1, :timer.hours(1))
      assert :ok = RateLimit.hit(ctx.key <> ":other", 1, :timer.hours(1))
    end

    test "remaining/3 reports without spending", ctx do
      assert RateLimit.remaining(ctx.key, 5, :timer.hours(1)) == 5
      assert :ok = RateLimit.hit(ctx.key, 5, :timer.hours(1))
      assert RateLimit.remaining(ctx.key, 5, :timer.hours(1)) == 4
      assert RateLimit.remaining(ctx.key, 5, :timer.hours(1)) == 4
    end

    test "a new window forgives", ctx do
      # A one-millisecond window has certainly rolled over by the next line.
      assert :ok = RateLimit.hit(ctx.key, 1, 1)
      Process.sleep(2)
      assert :ok = RateLimit.hit(ctx.key, 1, 1)
    end

    test "disabled, it allows everything", ctx do
      Application.put_env(:slipdock, :rate_limit, enabled: false)
      for _ <- 1..50, do: assert(:ok = RateLimit.hit(ctx.key, 1, :timer.hours(1)))
    end
  end
end
