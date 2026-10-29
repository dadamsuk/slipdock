defmodule Slipdock.RateLimitTest do
  # Global config and one shared ETS table.
  use ExUnit.Case, async: false

  alias Slipdock.RateLimit

  setup do
    previous = Application.get_env(:slipdock, :rate_limit)
    Application.put_env(:slipdock, :rate_limit, enabled: true)
    RateLimit.reset()

    on_exit(fn ->
      Application.put_env(:slipdock, :rate_limit, previous)
      RateLimit.reset()
    end)
  end

  describe "cooldown/3" do
    test "allows the first use and refuses the next until the gap has passed" do
      assert RateLimit.cooldown("k", 60_000, 1_000) == :ok
      assert RateLimit.cooldown("k", 60_000, 1_001) == {:error, 60}
      assert RateLimit.cooldown("k", 60_000, 60_999) == {:error, 1}
      assert RateLimit.cooldown("k", 60_000, 61_000) == :ok
      assert RateLimit.cooldown("k", 60_000, 61_001) == {:error, 60}
    end

    test "two uses either side of a minute boundary are not both allowed" do
      # The flake in #1160: hit/3's fixed window let these both through.
      assert RateLimit.cooldown("edge", 60_000, 119_996) == :ok
      assert RateLimit.cooldown("edge", 60_000, 120_001) == {:error, 60}
    end

    test "keys are separate" do
      assert RateLimit.cooldown("a", 60_000, 0) == :ok
      assert RateLimit.cooldown("b", 60_000, 1) == :ok
      assert RateLimit.cooldown("a", 60_000, 2) == {:error, 60}
    end

    test "a refused use does not push the gap back" do
      assert RateLimit.cooldown("k", 10_000, 0) == :ok
      assert {:error, _} = RateLimit.cooldown("k", 10_000, 9_000)
      assert RateLimit.cooldown("k", 10_000, 10_000) == :ok
    end

    test "concurrent callers after the gap get exactly one use" do
      assert RateLimit.cooldown("race", 1_000, 0) == :ok

      results =
        1..50
        |> Task.async_stream(fn _ -> RateLimit.cooldown("race", 1_000, 5_000) end)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &(&1 == :ok)) == 1
    end

    test "always allows when rate limiting is off" do
      Application.put_env(:slipdock, :rate_limit, enabled: false)

      assert RateLimit.cooldown("off", 60_000, 0) == :ok
      assert RateLimit.cooldown("off", 60_000, 1) == :ok
    end

    test "uses the real clock by default" do
      assert RateLimit.cooldown("clock", 60_000) == :ok
      assert {:error, s} = RateLimit.cooldown("clock", 60_000)
      assert s in 59..60
    end
  end

  describe "hit/3 and remaining/3" do
    defp at(ms), do: Application.put_env(:slipdock, :rate_limit, enabled: true, now: ms)

    test "allows the limit within a window, then refuses with the time to the reset" do
      at(60_000 + 15_000)

      assert RateLimit.hit("h", 2, 60_000) == :ok
      assert RateLimit.remaining("h", 2, 60_000) == 1
      assert RateLimit.hit("h", 2, 60_000) == :ok
      assert RateLimit.remaining("h", 2, 60_000) == 0
      assert RateLimit.hit("h", 2, 60_000) == {:error, 46}
      assert RateLimit.remaining("h", 2, 60_000) == 0
    end

    test "a pinned clock keeps a burst in one window" do
      # The flake in #1480: a burst read the real clock, crossed a minute
      # edge, and the count started again from zero partway through.
      at(119_999)
      for _ <- 1..3, do: assert(RateLimit.hit("burst", 3, 60_000) == :ok)
      assert {:error, 1} = RateLimit.hit("burst", 3, 60_000)
    end

    test "the next window starts a fresh count" do
      at(119_999)
      assert RateLimit.hit("edge", 1, 60_000) == :ok
      assert {:error, _} = RateLimit.hit("edge", 1, 60_000)

      at(120_000)
      assert RateLimit.remaining("edge", 1, 60_000) == 1
      assert RateLimit.hit("edge", 1, 60_000) == :ok
    end

    test "always allows when rate limiting is off, and records nothing" do
      Application.put_env(:slipdock, :rate_limit, enabled: false, now: 0)

      for _ <- 1..3, do: assert(RateLimit.hit("off", 1, 60_000) == :ok)
      assert RateLimit.remaining("off", 1, 60_000) == 1
    end

    test "reads the real clock when none is pinned" do
      assert RateLimit.hit("real", 1, :timer.hours(1)) == :ok
      assert {:error, s} = RateLimit.hit("real", 1, :timer.hours(1))
      assert s in 1..3600
    end
  end
end
