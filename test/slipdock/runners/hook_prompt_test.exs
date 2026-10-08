defmodule Slipdock.Runners.HookPromptTest do
  # The prompt that has Claude write a runner's hooks, and the worked example
  # it points at: what it promises, where it is shown, and that the example
  # does what it says.
  use SlipdockWeb.ConnCase, async: true

  alias Slipdock.Runners.HookPrompt

  @moduletag :anonymous
  @root Path.expand("../../..", __DIR__)

  describe "the prompt" do
    test "lists every variable a hook gets, for the shell runner" do
      text = HookPrompt.text("server", "https://slipdock.example/")

      for var <- ~w(SLIPDOCK_JOB_ID SLIPDOCK_JOB_KIND SLIPDOCK_CARD SLIPDOCK_CARD_URL
                    SLIPDOCK_STATUS SLIPDOCK_EXIT) do
        assert text =~ "- $#{var}: ", var
      end

      assert HookPrompt.env_vars() |> length() == 6
      assert text =~ "$SLIPDOCK_STATUS: how the job ended: done, failed, cancelled or timeout"
      assert text =~ "~/.config/slipdock-runner/config"
      assert text =~ "before_job() { ~/.local/bin/slipdock-hook before; }"
      refute text =~ "$env:"
    end

    test "states the contract: exit 0, its own log, and cards are the server's" do
      text = HookPrompt.text("server", "https://slipdock.example")

      assert text =~ "Exit 0, always."
      assert text =~ "Keep your own log file."
      assert text =~ "Don't move, flag, complete or comment on cards."
      assert text =~ "requeue_stuck"
      assert text =~ "job_finished"
      assert text =~ "PushOver, ntfy, Slack, email"
      assert text =~ "mentions $SLIPDOCK_CARD_URL"
      assert text =~ "--session-id"
    end

    test "points at the worked example on this server, without a doubled slash" do
      text = HookPrompt.text("server", "https://slipdock.example/")
      assert text =~ "https://slipdock.example/runner/examples/after-job-hook.sh\n"
      assert text =~ "https://slipdock.example/runner/examples/after-job-hook-test.sh\n"
    end

    test "is PowerShell for the Windows runner" do
      text = HookPrompt.text("windows", "https://slipdock.example")
      assert text =~ "- $env:SLIPDOCK_STATUS: "
      assert text =~ "config.ps1"
      assert text =~ "function After-Job"
      assert text =~ "translate it"
    end

    test "is for the runners that run hooks on your machine" do
      assert HookPrompt.for_scenario?("server")
      assert HookPrompt.for_scenario?("windows")
      refute HookPrompt.for_scenario?("loop")
      refute HookPrompt.for_scenario?("cloud")
    end

    test "is in the manual as the shell runner's prompt, word for word" do
      manual = File.read!(Path.join(@root, "docs/manual.md"))
      prompt = HookPrompt.text("server", "https://your-server")
      assert manual =~ "````text\n" <> String.trim_trailing(prompt) <> "\n````"
    end
  end

  describe "the worked example" do
    test "is served, and an unknown name is a 404", %{conn: conn} do
      for name <- HookPrompt.example_files() do
        body = conn |> get("/runner/examples/#{name}") |> response(200)
        assert body == File.read!(Path.join(@root, "priv/runner/examples/#{name}"))
      end

      assert conn |> get("/runner/examples/install.sh") |> response(404)
      assert conn |> get("/runner/examples/..%2Fslipdock-runner") |> response(404)
    end

    test "never touches the board: putting cards back is the server's" do
      script = File.read!(Path.join(@root, "priv/runner/examples/after-job-hook.sh"))
      refute script =~ ~r/^[^#\n]*slipdock (move|flag|comment|edit|done)/m
    end

    @tag :tmp_dir
    test "passes its own test", %{tmp_dir: tmp} do
      bash = System.find_executable("bash")

      if bash do
        dir = Path.join(@root, "priv/runner/examples")

        {out, status} =
          System.cmd(
            bash,
            [Path.join(dir, "after-job-hook-test.sh"), Path.join(dir, "after-job-hook.sh")],
            env: [{"TMPDIR", tmp}],
            stderr_to_stdout: true
          )

        assert status == 0, out
        assert out =~ ~r/\d+ passed, 0 failed/
      end
    end
  end
end
