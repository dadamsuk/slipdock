defmodule Slipdock.Runners.TranscriptSummaryTest do
  @moduledoc """
  A job's log summed up (#1877), on a recorded transcript fixture whose
  totals are known: a build job that reads a card and code, edits, fails a
  test, fails a compile, passes, commits, watches CI and submits.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Runners.TranscriptSummary

  @fixture File.read!("test/support/fixtures/transcript_build_job.jsonl")

  setup_all do
    %{sum: TranscriptSummary.summarise(@fixture)}
  end

  test "the span, and the model's and the tools' time, add up", %{sum: sum} do
    assert sum.lines == 27
    assert sum.from == ~U[2026-11-05 10:00:00.000Z]
    assert sum.to == ~U[2026-11-05 10:10:50.000Z]
    assert sum.seconds == 650
    assert sum.model_seconds == 83
    assert sum.tool_seconds == 567
    assert sum.model_seconds + sum.tool_seconds == sum.seconds
  end

  test "tool time by kind, each stretch to the earliest call waiting", %{sum: sum} do
    assert sum.tools.tests == %{seconds: 180, calls: 2}
    assert sum.tools.checks == %{seconds: 60, calls: 1}
    assert sum.tools.ci == %{seconds: 300, calls: 1}
    assert sum.tools.git == %{seconds: 10, calls: 1}
    assert sum.tools.slipdock == %{seconds: 4, calls: 2}
    # Read and Grep side by side (1s each), and an `ls` that never answered
    # but held the time until the log ended (10s).
    assert sum.tools.reading == %{seconds: 12, calls: 3}
    assert sum.tools.editing == %{seconds: 1, calls: 1}
    assert sum.tools.subagents == %{seconds: 0, calls: 0}
    assert sum.tools.shell == %{seconds: 0, calls: 0}
    assert Map.keys(sum.tools) |> Enum.sort() == Enum.sort(TranscriptSummary.kinds())
  end

  test "the longest calls, with their lines; one with no answer isn't among them",
       %{sum: sum} do
    assert Enum.map(sum.longest, &{&1.line, &1.kind, &1.seconds}) == [
             {19, :ci, 300},
             {10, :tests, 120},
             {13, :checks, 60},
             {15, :tests, 60},
             {17, :git, 10}
           ]

    assert hd(sum.longest).what == "gh pr checks card-12 --watch --fail-fast"
    assert hd(sum.longest).result_line == 20
    assert length(TranscriptSummary.summarise(@fixture, longest: 2).longest) == 2
  end

  test "failed calls: an error result, and a non-zero exit code", %{sum: sum} do
    assert [test, compile] = sum.failed
    assert test.line == 10 and test.kind == :tests
    assert test.error =~ "Exit code 2"
    assert test.error =~ "1 test, 1 failure"
    assert compile.line == 13
    assert compile.error =~ "(CompileError) lib/app/card.ex:9"
  end

  test "what the agent said, with lines and times", %{sum: sum} do
    assert Enum.map(sum.messages, &{&1.line, &1.text}) == [
             {1, "Reading the card first."},
             {12, "The test fails: the id is missing. Fixing."},
             {22, "CI green; submitting."},
             {26, "Done."}
           ]

    assert hd(sum.messages).at == ~U[2026-11-05 10:00:05.000Z]
  end

  test "an empty log, and lines that aren't JSON" do
    sum = TranscriptSummary.summarise("")
    assert sum.lines == 0 and sum.seconds == 0 and sum.from == nil
    assert sum.messages == [] and sum.longest == [] and sum.failed == []

    sum = TranscriptSummary.summarise("not json\n{\"type\":\"user\"}\n")
    assert sum.lines == 1 and sum.seconds == 0
  end

  describe "kind/2" do
    test "a shell command by what its steps run" do
      for {command, kind} <- [
            {"mix test test/a_test.exs", :tests},
            {"cd /repo && MIX_ENV=test mix test --stale", :tests},
            {"mix format && mix test", :tests},
            {"mix pre_push", :checks},
            {"timeout 300 mix compile --warnings-as-errors", :checks},
            {"gh run watch 1 --exit-status > /dev/null", :ci},
            {"gh pr checks card-1 --watch", :ci},
            {"git status --short", :git},
            {"gh pr create --fill", :git},
            {"slipdock card 12", :slipdock},
            {"slipdock job-progress --step 'x' && git push", :git},
            {"sed -n 1,40p lib/a.ex", :reading},
            {"cat a | grep b", :reading},
            {"python3 script.py", :shell},
            {"slipdock comment 1 --body 'run mix test; then git push'", :slipdock},
            {~s(slipdock verify 1 accept --reason "mix test passed; gh pr checks green"),
             :slipdock}
          ] do
        assert TranscriptSummary.kind("Bash", %{"command" => command}) == kind, command
      end
    end

    test "the other tools by name" do
      assert TranscriptSummary.kind("Read", %{}) == :reading
      assert TranscriptSummary.kind("Grep", %{}) == :reading
      assert TranscriptSummary.kind("Edit", %{}) == :editing
      assert TranscriptSummary.kind("Write", %{}) == :editing
      assert TranscriptSummary.kind("Agent", %{}) == :subagents
      assert TranscriptSummary.kind("mcp__slipdock__get_card", %{}) == :other
      assert TranscriptSummary.kind("Bash", %{}) == :shell
    end
  end
end
