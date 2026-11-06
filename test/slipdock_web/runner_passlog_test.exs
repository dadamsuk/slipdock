defmodule SlipdockWeb.RunnerPasslogTest do
  @moduledoc """
  The reference pass log, `priv/runner/examples/passlog.sh`, run for real
  against a stand-in `slipdock` that records how it was called.
  """
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Runners.HookPrompt
  alias Slipdock.Wiki.GeneratedTitles

  @script Path.expand("../../priv/runner/examples/passlog.sh", __DIR__)
  @hook Path.expand("../../priv/runner/examples/after-job-hook.sh", __DIR__)

  @moduletag :tmp_dir

  # Prints its arguments one to a line, then the file it was given.
  @stub """
  #!/usr/bin/env bash
  printf '%s\\n' "$@" >"$STUB_OUT/args"
  while [ $# -gt 0 ]; do
    if [ "$1" = --file ]; then cat "$2" >"$STUB_OUT/body"; fi
    shift
  done
  exit ${STUB_EXIT:-0}
  """

  setup %{tmp_dir: tmp} do
    stub = Path.join(tmp, "slipdock")
    File.write!(stub, @stub)
    File.chmod!(stub, 0o755)

    transcript = Path.join(tmp, "t.jsonl")

    File.write!(
      transcript,
      """
      {"type":"user","message":{"content":"work on it"}}
      {"type":"assistant","message":{"content":[{"type":"text","text":"Found the bug."},{"type":"tool_use","name":"Bash"}]}}
      {"type":"assistant","message":{"content":[{"type":"text","text":"Fixed and pushed."}]}}
      """
    )

    %{stub: stub, transcript: transcript, tmp: tmp}
  end

  defp run(ctx, args, env \\ []) do
    base = [
      {"SLIPDOCK_PASSLOG_CLI", ctx.stub},
      {"STUB_OUT", ctx.tmp},
      {"SLIPDOCK_CARD", "775"},
      {"SLIPDOCK_CARD_URL", "https://slipdock.example/boards/3/cards/775"},
      {"SLIPDOCK_JOB_ID", "41"}
    ]

    System.cmd("bash", [@script | args], env: base ++ env, stderr_to_stdout: true)
  end

  defp called(ctx), do: ctx.tmp |> Path.join("args") |> File.read!() |> String.split("\n")

  test "writes the page for the card, titled with the card and the time", ctx do
    assert {_, 0} = run(ctx, [ctx.transcript, "--exit", "0"])

    assert ["page", "new", "3", title | rest] = called(ctx)
    assert title =~ ~r/\APass 775 \(\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\)\z/
    assert ["--file", _, "--card", "775" | _] = rest
  end

  test "its title is what the migration maps an old one to" do
    assert GeneratedTitles.pass_log("Pass log #775: Fix it (2026-10-18 01:09)") ==
             "Pass 775 (2026-10-18 01.09)"
  end

  test "the title says nothing of the card's", ctx do
    assert {_, 0} = run(ctx, [ctx.transcript, "--exit", "0"])
    [_, _, _, title | _] = called(ctx)
    refute title =~ "Pass log"
    refute title =~ "#"
  end

  test "the page holds what the agent said, the job and the exit code", ctx do
    assert {_, 0} = run(ctx, [ctx.transcript, "--exit", "3"])
    body = ctx.tmp |> Path.join("body") |> File.read!()

    assert body =~ "Pass on #775, job #41, exit 3."

    if System.find_executable("jq") do
      assert body =~ "Found the bug."
      assert body =~ "Fixed and pushed."
      refute body =~ "tool_use"
      refute body =~ "work on it"
    end
  end

  test "a board named in the environment wins over the card's link", ctx do
    assert {_, 0} =
             run(ctx, [ctx.transcript, "--exit", "0"], [{"SLIPDOCK_PASSLOG_BOARD", "ops"}])

    assert ["page", "new", "ops" | _] = called(ctx)
  end

  test "with no board to be had it says so and writes nothing", ctx do
    assert {out, 1} = run(ctx, [ctx.transcript, "--exit", "0"], [{"SLIPDOCK_CARD_URL", ""}])
    assert out =~ "SLIPDOCK_PASSLOG_BOARD"
    refute File.exists?(Path.join(ctx.tmp, "args"))
  end

  test "with no card, or no transcript, likewise", ctx do
    assert {out, 1} = run(ctx, [ctx.transcript, "--exit", "0"], [{"SLIPDOCK_CARD", ""}])
    assert out =~ "SLIPDOCK_CARD"

    assert {out, 1} = run(ctx, [Path.join(ctx.tmp, "gone.jsonl"), "--exit", "0"])
    assert out =~ "no transcript"
    refute File.exists?(Path.join(ctx.tmp, "args"))
  end

  test "a failing CLI fails the script, for the hook to log", ctx do
    assert {_, 7} = run(ctx, [ctx.transcript, "--exit", "0"], [{"STUB_EXIT", "7"}])
  end

  test "the hook runs it, and a clean pass writes the page", ctx do
    state = Path.join(ctx.tmp, "state")
    transcripts = Path.join(ctx.tmp, "transcripts")
    File.mkdir_p!(transcripts)

    env = [
      {"SLIPDOCK_PASSLOG_CLI", ctx.stub},
      {"STUB_OUT", ctx.tmp},
      {"SLIPDOCK_HOOK_LOG", Path.join(ctx.tmp, "log")},
      {"SLIPDOCK_HOOK_STATE", state},
      {"SLIPDOCK_HOOK_TRANSCRIPTS", transcripts},
      {"SLIPDOCK_HOOK_PASSLOG", @script},
      {"SLIPDOCK_JOB_ID", "41"},
      {"SLIPDOCK_CARD", "775"},
      {"SLIPDOCK_CARD_URL", "https://slipdock.example/boards/3/cards/775"},
      {"SLIPDOCK_STATUS", "done"},
      {"SLIPDOCK_EXIT", "0"}
    ]

    assert {_, 0} = System.cmd("bash", [@hook, "before"], env: env, stderr_to_stdout: true)
    # `find -newer` compares file times, so the transcript has to be later.
    Process.sleep(20)

    File.write!(
      Path.join(transcripts, "s.jsonl"),
      ~s({"prompt":"https://slipdock.example/boards/3/cards/775"}\n)
    )

    assert {_, 0} = System.cmd("bash", [@hook, "after"], env: env, stderr_to_stdout: true)
    assert ["page", "new", "3", "Pass 775 (" <> _ | _] = called(ctx)
  end

  describe "the hook's pass log is opt-in (#1873)" do
    # A job's run through the hook, before and after, with `extra` in its
    # environment: whether the stand-in CLI was asked to write a page.
    defp hook_pass(ctx, extra) do
      transcripts = Path.join(ctx.tmp, "transcripts")
      File.mkdir_p!(transcripts)

      env =
        [
          {"SLIPDOCK_PASSLOG_CLI", ctx.stub},
          {"STUB_OUT", ctx.tmp},
          {"SLIPDOCK_HOOK_LOG", Path.join(ctx.tmp, "log")},
          {"SLIPDOCK_HOOK_STATE", Path.join(ctx.tmp, "state")},
          {"SLIPDOCK_HOOK_TRANSCRIPTS", transcripts},
          {"SLIPDOCK_JOB_ID", "41"},
          {"SLIPDOCK_CARD", "775"},
          {"SLIPDOCK_CARD_URL", "https://slipdock.example/boards/3/cards/775"},
          {"SLIPDOCK_STATUS", "done"},
          {"SLIPDOCK_EXIT", "0"}
        ] ++ extra

      assert {_, 0} = System.cmd("bash", [@hook, "before"], env: env, stderr_to_stdout: true)
      transcript = Path.join(transcripts, "s.jsonl")
      File.write!(transcript, ~s({"prompt":"https://slipdock.example/boards/3/cards/775"}\n))
      # Later than the job's start mark, without waiting for the clock.
      later = :calendar.universal_time() |> :calendar.datetime_to_gregorian_seconds()
      File.touch!(transcript, later + 60)

      assert {_, 0} = System.cmd("bash", [@hook, "after"], env: env, stderr_to_stdout: true)
      File.exists?(Path.join(ctx.tmp, "args"))
    end

    test "by default the hook writes no page, and still logs the job", ctx do
      # SLIPDOCK_HOOK_PASSLOG is unset in the hook's environment.
      refute hook_pass(ctx, [{"SLIPDOCK_HOOK_PASSLOG", nil}])

      assert File.read!(Path.join(ctx.tmp, "log")) =~
               "job #41 on card #775 finished (done, exit 0)"
    end

    test "set but empty is off too", ctx do
      refute hook_pass(ctx, [{"SLIPDOCK_HOOK_PASSLOG", ""}])
    end

    test "set, it writes the page", ctx do
      assert hook_pass(ctx, [{"SLIPDOCK_HOOK_PASSLOG", @script}])
      assert ["page", "new", "3", "Pass 775 (" <> _ | _] = called(ctx)
    end

    test "the hook and the pass log say why it is off, and what keeps a log instead" do
      hook = File.read!(@hook)
      assert hook =~ "Pass log, off unless SLIPDOCK_HOOK_PASSLOG is set"
      assert hook =~ "Keep this log (`slipdock job <id> --keep`)"
      assert File.read!(@script) =~ "Opt-in (#1873)"
    end
  end

  test "is served with the other examples", %{conn: conn} do
    assert "passlog.sh" in HookPrompt.example_files()
    body = conn |> get("/runner/examples/passlog.sh") |> response(200)
    assert body == File.read!(@script)
  end

  test "is executable, and touches the board only to write its page" do
    assert Bitwise.band(File.stat!(@script).mode, 0o111) != 0
    refute File.read!(@script) =~ ~r/^[^#\n]*slipdock (move|flag|comment|edit|done)/m
  end
end
