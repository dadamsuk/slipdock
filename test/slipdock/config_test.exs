defmodule Slipdock.ConfigTest do
  @moduledoc """
  A test's config override: seen by the test and what it starts, by nobody
  else, and gone when it is cleared. Async on purpose — running alongside
  other tests is what the override is for.
  """
  use ExUnit.Case, async: true

  alias Slipdock.{Config, TestConfig}

  # Not a key the application reads, so nothing else in the suite cares.
  @key :config_test_key

  test "without an override, it is the application env, or the default" do
    assert Config.get(@key) == nil
    assert Config.get(@key, :fallback) == :fallback
    assert Config.get(:base_url) == Application.get_env(:slipdock, :base_url)
  end

  test "an override wins over the application env, for this process" do
    TestConfig.put(:base_url, "http://overridden.test")

    assert Config.get(:base_url) == "http://overridden.test"
    assert Application.get_env(:slipdock, :base_url) != "http://overridden.test"
  end

  test "a nil or false override is still an override, not a miss" do
    TestConfig.put(:base_url, nil)
    assert Config.get(:base_url, "default") == nil

    TestConfig.put(@key, false)
    assert Config.get(@key, true) == false
  end

  test "what the test starts sees it, through $callers" do
    TestConfig.put(@key, :mine)

    assert Task.async(fn -> Config.get(@key) end) |> Task.await() == :mine

    # Two levels down: a task started by a task.
    nested = Task.async(fn -> Task.async(fn -> Config.get(@key) end) |> Task.await() end)
    assert Task.await(nested) == :mine
  end

  test "a process the test did not start does not see it" do
    TestConfig.put(@key, :mine)
    parent = self()

    spawn(fn -> send(parent, {:seen, Config.get(@key, :unset)}) end)

    assert_receive {:seen, :unset}
  end

  test "two processes' overrides of the same key do not mix" do
    TestConfig.put(@key, :mine)
    parent = self()

    spawn(fn ->
      Config.override(@key, :theirs)
      send(parent, {:seen, Config.get(@key)})
      Config.clear_overrides(self())
    end)

    assert_receive {:seen, :theirs}
    assert Config.get(@key) == :mine
  end

  test "clear_overrides/1 drops every key that process set" do
    Config.override(@key, 1)
    Config.override(:base_url, "http://cleared.test")

    Config.clear_overrides(self())

    assert Config.get(@key) == nil
    assert Config.get(:base_url) == Application.get_env(:slipdock, :base_url)
  end

  test "merge/2 merges into the keyword list the key holds" do
    TestConfig.put(@key, a: 1, b: 2)
    TestConfig.merge(@key, b: 3, c: 4)

    assert Config.get(@key) == [a: 1, b: 3, c: 4]
  end

  test "merge/2 on an unset key starts from an empty list" do
    TestConfig.merge(@key, a: 1)
    assert Config.get(@key) == [a: 1]
  end
end
