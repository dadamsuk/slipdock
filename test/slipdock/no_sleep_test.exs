defmodule Slipdock.NoSleepTest do
  @moduledoc """
  TEST-14's check (#2608): a test doesn't wait with `Process.sleep/1`.

  A fixed sleep races whatever it waits for, and loses on a slow CI runner
  (#1651, #1837). Monitor the process and `assert_receive` its `:DOWN`, or
  call `:sys.get_state/1` to let it finish what it was sent.

  This is a ratchet. It reads every `.ex` and `.exs` under `test/` and
  `cli/test/` and counts the calls to `Process.sleep/1` and `:timer.sleep/1`
  (from the code, so a comment or a string that names one isn't counted). A
  file may hold no more than `@allowed` gives it: a new sleep fails here, in
  `mix pre_push`, before the verifier rejects it (#2571 was, for three). A
  file holding fewer than its allowance fails too, so the allowance comes
  down in the same change that removes one, and never goes back up.

  The allowance is what was on main when the check came in. Raising one, or
  adding a file, needs a reason a sleep is not a wait (a stand-in process
  that must never return, say), written beside it.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @before "on main before TEST-14's check (#2608): wait on a :DOWN or :sys.get_state/1 instead"

  # file => {how many sleeps it may hold, why}.
  @allowed %{
    "test/slipdock_web/endpoint_shutdown_test.exs" =>
      {1, "Process.sleep(:infinity) is a request that must never finish, not a wait"},
    "test/slipdock/posthog/error_tracking_test.exs" => {1, @before},
    "test/slipdock/runners/claim_drain_test.exs" => {1, @before},
    "test/slipdock/runners/pause_test.exs" => {1, @before},
    "test/slipdock/runners/probe_test.exs" => {1, @before},
    "test/slipdock/runners_test.exs" => {1, @before},
    "test/slipdock/sandbox_queue_test.exs" => {1, @before},
    "test/slipdock/signups_test.exs" => {1, @before},
    "test/slipdock/wiki/drawing_session_test.exs" => {1, @before},
    "test/slipdock_web/live/drawing_live_test.exs" => {1, @before},
    "test/slipdock_web/live/wiki_big_vault_test.exs" => {7, @before}
  }

  @doc false
  # The lines of `source` that call `Process.sleep/1` or `:timer.sleep/1`.
  def sleeps(source) do
    {_, lines} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn node, acc -> {node, sleep_line(node) ++ acc} end)

    Enum.sort(lines)
  end

  defp sleep_line({{:., meta, [{:__aliases__, _, [:Process]}, :sleep]}, _, [_]}),
    do: [meta[:line]]

  defp sleep_line({{:., meta, [:timer, :sleep]}, _, [_]}), do: [meta[:line]]
  defp sleep_line(_), do: []

  @doc false
  # What's wrong with `found` (file => sleep lines) against `allowed`
  # (file => {count, reason}): one message per file, sorted.
  def problems(found, allowed) do
    files = Enum.sort(Enum.uniq(Map.keys(found) ++ Map.keys(allowed)))

    for file <- files,
        lines = Map.get(found, file, []),
        {max, _} = Map.get(allowed, file, {0, nil}),
        message = problem(file, lines, max, Map.has_key?(allowed, file)),
        do: message
  end

  defp problem(file, lines, 0, false),
    do: "#{file} waits with a sleep on line #{Enum.join(lines, ", ")} (TEST-14)"

  defp problem(file, lines, max, _) when length(lines) > max,
    do:
      "#{file} has #{length(lines)} sleeps, lines #{Enum.join(lines, ", ")}; " <>
        "it may hold #{max} (TEST-14)"

  defp problem(file, lines, max, _) when length(lines) < max,
    do: "#{file} holds #{length(lines)} sleeps, fewer than its #{max}: lower @allowed to match"

  defp problem(_, _, _, _), do: nil

  defp scanned do
    for dir <- ["test", "cli/test"],
        path <- Path.wildcard(Path.join([@root, dir, "**/*.{ex,exs}"])),
        do: Path.relative_to(path, @root)
  end

  defp found do
    for path <- scanned(),
        lines = sleeps(File.read!(Path.join(@root, path))),
        lines != [],
        into: %{},
        do: {path, lines}
  end

  describe "the repository" do
    test "no test waits with a sleep beyond its file's allowance" do
      assert problems(found(), @allowed) == []
    end

    test "it reads the server's tests and the CLI's, support files too" do
      files = scanned()
      assert "test/slipdock/no_sleep_test.exs" in files
      assert "test/support/data_case.ex" in files
      assert Enum.any?(files, &String.starts_with?(&1, "cli/test/"))
    end

    test "every allowance says why" do
      for {file, {max, reason}} <- @allowed do
        assert max > 0, "#{file} is allowed none: drop it from @allowed"
        assert is_binary(reason) and reason != "", "#{file} gives no reason"
      end
    end
  end

  describe "sleeps/1" do
    test "finds Process.sleep and :timer.sleep, by line" do
      source = """
      defmodule T do
        def a, do: Process.sleep(10)

        def b do
          :timer.sleep(5)
          Process.sleep(:infinity)
        end
      end
      """

      assert sleeps(source) == [2, 5, 6]
    end

    test "doesn't count a comment, a string or another sleep" do
      source = ~S'''
      defmodule T do
        # Process.sleep(100) would race the window
        @doc "not Process.sleep(100)"
        def a, do: Repo.query!("SELECT pg_sleep(1)")
        def b(m), do: m.sleep(1)
        def c, do: Process.send_after(self(), :tick, 10)
      end
      '''

      assert sleeps(source) == []
    end
  end

  describe "problems/2" do
    test "a sleep in a file not on the list fails, naming the file and line" do
      assert problems(%{"test/a_test.exs" => [12]}, %{}) ==
               ["test/a_test.exs waits with a sleep on line 12 (TEST-14)"]
    end

    test "more sleeps than the allowance fails" do
      assert [message] =
               problems(%{"test/a_test.exs" => [3, 9]}, %{"test/a_test.exs" => {1, "x"}})

      assert message =~ "has 2 sleeps, lines 3, 9; it may hold 1"
    end

    test "fewer than the allowance fails, so the ratchet comes down" do
      assert [message] = problems(%{"test/a_test.exs" => [3]}, %{"test/a_test.exs" => {2, "x"}})
      assert message =~ "fewer than its 2"
      assert [gone] = problems(%{}, %{"test/a_test.exs" => {1, "x"}})
      assert gone =~ "holds 0 sleeps, fewer than its 1"
    end

    test "a file at its allowance, or with none, passes" do
      assert problems(%{"test/a_test.exs" => [3]}, %{"test/a_test.exs" => {1, "x"}}) == []
      assert problems(%{}, %{}) == []
    end
  end
end
