defmodule SlipdockCLI.StdinSwitchesTest do
  @moduledoc """
  `-` as a free-text switch's value reads the text from stdin (#2678), as
  `comment --body -` does: `add --desc -` with a heredoc used to store the
  description as a literal `-`. Each switch here is parsed from argv as a
  person types it, so the request shows what reached the server. A plain
  value is still the text itself. Empty stdin ends in `System.halt/1`, so
  its message is checked on `Util.stdin_text/2`, which decides it.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Automations, Boards, FakeServer, Findings, Machines, Runners, Util}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-stdin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  @markdown "Flake in `x_test.exs`.\n\n- seed 1234\n- `{:error, :timeout}`\n"

  # Runs `mod.run(cmd, args, opts)` with argv's switches (and --json, so the
  # output is the server's answer as given), `input` on stdin; returns what
  # was sent.
  defp sent(mod, cmd, args, argv, input, method, path) do
    {opts, _, []} = OptionParser.parse(argv ++ ["--json"], strict: SlipdockCLI.switches())
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, ~s({"ok":true})}]))
    capture_io([input: input], fn -> mod.run(cmd, args, opts) end)
    assert_received {:request, ^method, ^path, body}
    JSON.decode!(body)
  end

  describe "add" do
    test "--desc - reads the description from stdin, lines and all" do
      body =
        sent(
          Boards,
          "add",
          ["b", "Flake"],
          ["--desc", "-"],
          @markdown,
          "POST",
          "/api/boards/b/cards"
        )

      assert body["description"] == @markdown
      assert body["title"] == "Flake"
    end

    test "--bar - reads the bar from stdin" do
      body =
        sent(
          Boards,
          "add",
          ["b", "Flake"],
          ["--bar", "-"],
          "one\ntwo\n",
          "POST",
          "/api/boards/b/cards"
        )

      assert body["bar"] == "one\ntwo\n"
      refute Map.has_key?(body, "description")
    end

    test "--desc TEXT is the text itself, and stdin is left alone" do
      body =
        sent(
          Boards,
          "add",
          ["b", "Flake"],
          ["--desc", "as typed"],
          "unread",
          "POST",
          "/api/boards/b/cards"
        )

      assert body["description"] == "as typed"
    end
  end

  describe "edit" do
    test "--desc - reads the description from stdin" do
      body = sent(Boards, "edit", ["7"], ["--desc", "-"], @markdown, "PATCH", "/api/cards/7")
      assert body == %{"description" => @markdown}
    end

    test "--bar - reads the bar from stdin" do
      body =
        sent(
          Boards,
          "edit",
          ["7"],
          ["--bar", "-"],
          "done when\nit ships\n",
          "PATCH",
          "/api/cards/7"
        )

      assert body == %{"bar" => "done when\nit ships\n"}
    end

    test "--desc TEXT is the text itself" do
      body = sent(Boards, "edit", ["7"], ["--desc", "plain"], "", "PATCH", "/api/cards/7")
      assert body == %{"description" => "plain"}
    end
  end

  describe "the other free-text switches" do
    test "new-board, set-board and new-template --desc -" do
      body = sent(Boards, "new-board", ["Ops"], ["--desc", "-"], @markdown, "POST", "/api/boards")
      assert body["description"] == @markdown

      body =
        sent(Boards, "set-board", ["ops"], ["--desc", "-"], @markdown, "PATCH", "/api/boards/ops")

      assert body == %{"description" => @markdown}

      body =
        sent(
          Boards,
          "new-template",
          ["T"],
          ["--desc", "-", "--list", "To Do"],
          @markdown,
          "POST",
          "/api/templates"
        )

      assert body["description"] == @markdown
    end

    test "done --no-code - reads why from stdin" do
      body =
        sent(
          Boards,
          "done",
          ["7"],
          ["--no-code", "-"],
          "a sweep:\nnothing to change\n",
          "PATCH",
          "/api/cards/7"
        )

      assert body["evidence_no_code"] == "a sweep:\nnothing to change\n"
      assert body["completed"] == true
    end

    test "verify reject --reason - reads the reason from stdin, which satisfies the check" do
      body =
        sent(
          Boards,
          "verify",
          ["7", "reject"],
          ["--reason", "-"],
          @markdown,
          "POST",
          "/api/cards/7/verify"
        )

      assert body == %{"decision" => "reject", "reason" => @markdown}
    end

    test "wait --withdraw --reason - sends the piped reason" do
      {opts, _, []} =
        OptionParser.parse(["--withdraw", "--reason", "-", "--json"],
          strict: SlipdockCLI.switches()
        )

      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, ~s({"wait":{"needs":"x"}})}]))
      capture_io([input: "answered on #12"], fn -> Boards.run("wait", ["7"], opts) end)
      assert_received {:request, "DELETE", path, _}
      assert path == "/api/cards/7/wait?reason=answered+on+%2312"
    end

    test "finish-job --summary - reads the summary from stdin" do
      body =
        sent(
          Runners,
          "finish-job",
          ["9"],
          ["--summary", "-"],
          @markdown,
          "POST",
          "/api/jobs/9/finish"
        )

      assert body == %{"outcome" => "done", "summary" => @markdown}
    end

    test "finding dismiss --note - reads the note from stdin" do
      body =
        sent(
          Findings,
          "finding",
          ["5", "dismiss"],
          ["--note", "-"],
          "a one-off\n",
          "PATCH",
          "/api/findings/5"
        )

      assert body == %{"action" => "dismiss", "note" => "a one-off\n"}
    end
  end

  # The four #2678 left out (#2765).
  describe "runner --instructions, set-automation --text, finish-job --needs, sprint --goal" do
    test "runner new --instructions - reads the instructions from stdin" do
      body =
        sent(
          Runners,
          "runner",
          ["new", "b"],
          ["--pool", "p", "--instructions", "-"],
          @markdown,
          "POST",
          "/api/boards/b/runners/setup"
        )

      assert body["instructions"] == @markdown
      assert body["scenario"] == "daemon"
    end

    test "machine set-runner and add-runner --instructions - read them from stdin" do
      body =
        sent(
          Machines,
          "machine",
          ["set-runner", "4", "12"],
          ["--instructions", "-"],
          @markdown,
          "PATCH",
          "/api/machines/4/runners/12"
        )

      assert body["config"] == %{"instructions" => @markdown}

      body =
        sent(
          Machines,
          "machine",
          ["add-runner", "4", "b"],
          ["--pool", "p", "--dir", "/w", "--instructions", "-"],
          "one\ntwo\n",
          "POST",
          "/api/machines/4/runners"
        )

      assert body["config"]["instructions"] == "one\ntwo\n"
      assert body["config"]["directory"] == "/w"
    end

    test "machine set-runner and add-runner send any other config switch's dash as typed" do
      body =
        sent(
          Machines,
          "machine",
          ["set-runner", "4", "12"],
          ["--model", "-", "--dir", "-"],
          "unread",
          "PATCH",
          "/api/machines/4/runners/12"
        )

      assert body["config"] == %{"model" => "-", "directory" => "-"}

      body =
        sent(
          Machines,
          "machine",
          ["add-runner", "4", "b"],
          ["--pool", "p", "--dir", "/w", "--agent", "-", "--instructions", "-"],
          "only these\n",
          "POST",
          "/api/machines/4/runners"
        )

      assert body["config"]["agent"] == "-"
      assert body["config"]["instructions"] == "only these\n"
    end

    test "set-automation --text - reads the rule's words from stdin" do
      body =
        sent(
          Automations,
          "set-automation",
          ["b", "3"],
          ["--text", "-"],
          "when a card lands in Done\nemail me\n",
          "PATCH",
          "/api/boards/b/automations/3"
        )

      assert body == %{"text" => "when a card lands in Done\nemail me\n"}
    end

    test "finish-job --status waiting --needs - reads the question from stdin" do
      body =
        sent(
          Runners,
          "finish-job",
          ["9"],
          ["--status", "waiting", "--needs", "-"],
          "Which region?\nEU or US.\n",
          "POST",
          "/api/jobs/9/finish"
        )

      assert body["wait"]["needs"] == "Which region?\nEU or US.\n"
    end

    test "sprint --goal - reads the goal from stdin" do
      body =
        sent(
          Boards,
          "sprint",
          ["b"],
          ["--goal", "-"],
          "ship runners\n",
          "POST",
          "/api/boards/b/sprints"
        )

      assert body == %{"goal" => "ship runners\n"}
    end

    test "each as plain text is the text itself" do
      body =
        sent(
          Automations,
          "set-automation",
          ["b", "3"],
          ["--text", "as typed"],
          "unread",
          "PATCH",
          "/api/boards/b/automations/3"
        )

      assert body == %{"text" => "as typed"}

      body =
        sent(Boards, "sprint", ["b"], ["--goal", "plain"], "", "POST", "/api/boards/b/sprints")

      assert body == %{"goal" => "plain"}
    end
  end

  test "empty or blank stdin is refused, naming the switch, rather than sent" do
    assert Util.stdin_text(:eof, "--desc") == {:error, "nothing on stdin for --desc -"}
    assert Util.stdin_text("  \n", "--bar") == {:error, "nothing on stdin for --bar -"}
    assert Util.stdin_text("text", "--desc") == {:ok, "text"}
    assert Util.stdin_arg(nil, "--desc") == nil
    assert Util.stdin_arg("--", "--desc") == "--"
  end
end
