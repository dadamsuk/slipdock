defmodule Slipdock.FlakyPatternsTest do
  @moduledoc ~S"""
  The flaky-test causes that can be seen in the code (#3163, W-1950 §Tests,
  "Flaky tests: the causes").

  About 40 cards from 2026-11-03 were one flaky test each. Most came from a
  handful of causes, and three of them leave a mark in the source, so this
  check fails on them in `mix pre_push` and in CI:

  - **A short id refuted against a whole document** (#3146, #2942, #2849):
    `refute html =~ page.code`, or `refute text =~ "##{card.id}"`. A code
    like `W-31` turns up by chance in a LiveView's session tokens, and an
    id inside a longer one (`#12` in `#120`). Use
    `SlipdockWeb.PageText.refute_mentions/2` or `mentions?/2`, which read
    the text and match the whole token, or select an element.
  - **A log line from a LiveView's async task, captured** (#3154, #3155):
    `capture_log`/`with_log` around `render_async/1` keeps only what was
    logged before it returns, and the task's crash report comes after. Use
    `Slipdock.AwaitLog`, which waits for the line.
  - **A wait shorter than the suite's** (#2830, #2870, #2828): an
    `assert_receive` or `render_async` given a literal timeout under the 5 s
    `assert_receive_timeout` in `test/test_helper.exs`. It only makes a
    failing assert fail sooner, and a passing one on a loaded runner fail.
    Leave the timeout out. (Under `test/` only: the CLI's suite in
    `cli/test` keeps ExUnit's 100 ms default, so a longer literal there is
    the fix, not the fault.) A timeout of 0 means "already received" and is
    left alone.

  It reads the code, not the text: a comment or a string naming one of these
  isn't counted. There is no allowance: each site on main was fixed when the
  check came in.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # assert_receive_timeout in test/test_helper.exs, held by
  # test/slipdock/test_helper_config_test.exs.
  @suite_wait 5_000

  @doc false
  # Every risky site in `source`: `{line, kind}`, sorted. `waits?` says
  # whether the short-wait check applies (the server's suite, not the CLI's).
  def findings(source, waits? \\ true) do
    {_, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn node, acc -> {node, finding(node, waits?) ++ acc} end)

    Enum.sort(found)
  end

  defp finding({:refute, meta, [{:=~, _, [_, needle]} | _]}, _),
    do: short_id(needle, meta)

  defp finding(
         {:refute, meta,
          [{{:., _, [{:__aliases__, _, [:String]}, :contains?]}, _, [_, needle]} | _]},
         _
       ),
       do: short_id(needle, meta)

  defp finding({capture, meta, args}, _)
       when capture in [:capture_log, :with_log] and is_list(args),
       do: async_capture(args, meta)

  defp finding(
         {{:., _, [{:__aliases__, _, [:ExUnit, :CaptureLog]}, capture]}, meta, args},
         _
       )
       when capture in [:capture_log, :with_log] and is_list(args),
       do: async_capture(args, meta)

  defp finding({wait, meta, [_, timeout]}, true)
       when wait in [:assert_receive, :render_async] and is_integer(timeout) and
              timeout > 0 and timeout < @suite_wait,
       do: [{meta[:line], :short_wait}]

  defp finding(_, _), do: []

  defp short_id(needle, meta) do
    if short_id?(needle), do: [{meta[:line], :short_id_refute}], else: []
  end

  # A record's code or shortcut, or a string that is all interpolation but
  # for at most one character (`"##{id}"`, `"#{card.id}"`).
  defp short_id?({{:., _, [_, field]}, _, []}) when field in [:code, :shortcut], do: true

  defp short_id?({:<<>>, _, parts}) do
    Enum.any?(parts, &(not is_binary(&1))) and
      parts |> Enum.filter(&is_binary/1) |> Enum.map(&String.length/1) |> Enum.sum() <= 1
  end

  defp short_id?(_), do: false

  defp async_capture(args, meta) do
    {_, async?} =
      Macro.prewalk(List.last(args), false, fn
        {:render_async, _, _} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    if async?, do: [{meta[:line], :async_log_capture}], else: []
  end

  @doc false
  def message({file, line, :short_id_refute}),
    do:
      "#{file}:#{line} refutes a short id against a whole document: " <>
        "use SlipdockWeb.PageText.refute_mentions/2 or mentions?/2, or select an element"

  def message({file, line, :async_log_capture}),
    do:
      "#{file}:#{line} captures the log around render_async, whose task logs after it: " <>
        "use Slipdock.AwaitLog.watch/0 and assert_logged/3"

  def message({file, line, :short_wait}),
    do:
      "#{file}:#{line} waits less than the suite's #{@suite_wait} ms: " <>
        "leave the timeout out"

  defp scanned do
    for dir <- ["test", "cli/test"],
        path <- Path.wildcard(Path.join([@root, dir, "**/*.{ex,exs}"])),
        do: Path.relative_to(path, @root)
  end

  defp all_findings do
    for path <- scanned(),
        waits? = String.starts_with?(path, "test/"),
        {line, kind} <- findings(File.read!(Path.join(@root, path)), waits?),
        do: message({path, line, kind})
  end

  describe "the repository" do
    test "no test carries a flaky pattern the code shows" do
      assert all_findings() == []
    end

    test "it reads the server's tests and the CLI's, support files too" do
      files = scanned()
      assert "test/slipdock/flaky_patterns_test.exs" in files
      assert "test/support/page_text.ex" in files
      assert Enum.any?(files, &String.starts_with?(&1, "cli/test/"))
    end
  end

  describe "findings/2: a short id refuted" do
    test "a code, a shortcut or an id with a character beside it" do
      source = ~S'''
      defmodule T do
        test "x" do
          refute render(view) =~ page.code
          refute html =~ board.shortcut, "a message"
          refute body =~ "##{card.id}"
          refute body =~ "#{card.id}"
          refute String.contains?(html, ctx.page.code)
        end
      end
      '''

      assert findings(source) == [
               {3, :short_id_refute},
               {4, :short_id_refute},
               {5, :short_id_refute},
               {6, :short_id_refute},
               {7, :short_id_refute}
             ]
    end

    test "but not a literal, an id in context, an assert, or the helpers" do
      source = ~S'''
      defmodule T do
        test "x" do
          refute html =~ "W-31"
          refute html =~ "/boards/#{board.id}"
          refute html =~ "##{card.id} "
          refute html =~ page.title
          assert html =~ page.code
          refute PageText.mentions?(html, page.code)
          PageText.refute_mentions(view, page.code)
          # refute render(view) =~ page.code
          @doc "refute html =~ page.code"
        end
      end
      '''

      assert findings(source) == []
    end
  end

  describe "findings/2: a log captured around render_async" do
    test "capture_log or with_log, imported or in full" do
      source = ~S'''
      defmodule T do
        test "x" do
          capture_log(fn -> render_async(view) end)
          {_, log} = with_log(fn -> render_click(b); render_async(view) end)
          ExUnit.CaptureLog.with_log(fn ->
            html = render_async(view)
            html
          end)
          ExUnit.CaptureLog.capture_log([level: :error], fn -> render_async(view, 5_000) end)
        end
      end
      '''

      assert findings(source) == [
               {3, :async_log_capture},
               {4, :async_log_capture},
               {5, :async_log_capture},
               {9, :async_log_capture}
             ]
    end

    test "but not a capture of a synchronous call, nor render_async outside one" do
      source = ~S'''
      defmodule T do
        test "x" do
          capture_log(fn -> render_hook(view, "resync", %{}) end)
          log = AwaitLog.watch()
          render_async(view)
          AwaitLog.assert_logged(log, "blew up")
        end
      end
      '''

      assert findings(source) == []
    end
  end

  describe "findings/2: a wait shorter than the suite's" do
    test "assert_receive or render_async with a literal under 5 s" do
      source = ~S'''
      defmodule T do
        test "x" do
          assert_receive {:saved, _}, 1_000
          render_async(view, 2000)
          assert_receive :done, 4_999
        end
      end
      '''

      assert findings(source) == [{3, :short_wait}, {4, :short_wait}, {5, :short_wait}]
    end

    test "but not the default, 5 s or more, 0, refute_receive, or a name" do
      source = ~S'''
      defmodule T do
        test "x" do
          assert_receive {:saved, _}
          assert_receive :done, 5_000
          assert_receive :done, 0
          refute_receive :late, 200
          render_async(view, @timeout)
        end
      end
      '''

      assert findings(source) == []
    end

    test "and not in the CLI's suite, whose default is ExUnit's 100 ms" do
      source = "assert_receive {:request, _, _, _}, 2_000"
      assert findings(source, true) == [{1, :short_wait}]
      assert findings(source, false) == []
    end
  end

  describe "message/1" do
    test "names the file, the line and the fix for each kind" do
      assert message({"test/a_test.exs", 3, :short_id_refute}) =~
               ~r{^test/a_test.exs:3 .*PageText.refute_mentions/2}

      assert message({"test/a_test.exs", 4, :async_log_capture}) =~ "Slipdock.AwaitLog"
      assert message({"test/a_test.exs", 5, :short_wait}) =~ "leave the timeout out"
    end
  end
end
