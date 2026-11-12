defmodule Slipdock.TestHelperConfigTest do
  @moduledoc """
  What `test/test_helper.exs` starts ExUnit with, held where a change to it
  shows (#2828).

  `assert_receive` and `render_async` wait `assert_receive_timeout` for a
  LiveView's async task to come back. Under a loaded full run a second was not
  enough: the skill registry, quick note and header quick add tests timed out
  at `render_async` and passed alone. Only a failing assert waits the whole
  timeout, so a long one costs nothing on a green run.
  """
  use ExUnit.Case, async: true

  test "assert_receive and render_async wait long enough for a loaded run" do
    assert ExUnit.configuration()[:assert_receive_timeout] >= 5_000
  end

  test "a refute_receive is still short: a long one would slow every passing test" do
    assert ExUnit.configuration()[:refute_receive_timeout] <= 100
  end
end
