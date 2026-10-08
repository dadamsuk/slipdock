defmodule Slipdock.Runners.HookPrompt do
  @moduledoc """
  A prompt to paste into Claude Code on the runner's machine, which has it
  write that machine's before/after-job hooks: the notifier the person uses,
  and what to keep from each job.

  What is the same everywhere — putting back a card a job left in progress,
  and telling the board about it — is the server's job
  (`Slipdock.Runners.Recovery`, the `job_finished` trigger), so the prompt
  states the contract a hook works under and points at a worked example
  served from `/runner/examples/`, rather than having each person's Claude
  regenerate the delicate part.
  """

  @env [
    {"SLIPDOCK_JOB_ID", "the job's number", :both},
    {"SLIPDOCK_JOB_KIND", "the job's kind (claude, codex, …)", :both},
    {"SLIPDOCK_CARD", "the card's number", :both},
    {"SLIPDOCK_CARD_URL", "a link to the card", :both},
    {"SLIPDOCK_STATUS", "how the job ended: done, failed, cancelled or timeout", :after},
    {"SLIPDOCK_EXIT", "the job's exit code (124 timed out, 130 cancelled)", :after}
  ]

  @example "after-job-hook.sh"
  @example_test "after-job-hook-test.sh"

  @doc "The environment variables a hook is given, in order."
  def env_vars, do: Enum.map(@env, &elem(&1, 0))

  @doc "The worked example's file names, as served under `/runner/examples/`."
  def example_files, do: [@example, @example_test]

  @doc "Whether the scenario's runner runs hooks this prompt is for (the shell and Windows runners)."
  def for_scenario?(scenario), do: scenario in ~w(server windows)

  @doc """
  The prompt, for a runner of `scenario` (`"windows"` gets PowerShell, any
  other the shell runner) on the server at `base_url`.
  """
  def text(scenario, base_url) do
    base_url = String.trim_trailing(to_string(base_url), "/")
    windows? = scenario == "windows"

    """
    Write the before-job and after-job hooks for the Slipdock runner on this machine.

    The runner takes jobs from a Slipdock board and runs a coding agent on each card. #{shape(windows?)}

    The contract every hook works under:

    #{env_list(windows?)}
    - Exit 0, always. A before-job hook that fails stops the job from running, and an after-job hook runs before the runner reports the job finished, so neither may block, hang or fail it: wrap every step so a failure is logged and skipped, and put a time limit on anything that calls the network (well under a minute in all).
    - Keep your own log file. What a hook prints goes into the job's log, whose tail the board shows as the job's output, so never print secrets there.
    - Don't move, flag, complete or comment on cards. Putting back a card a job left in progress is the server's job (the rule's "Put a card left in progress back, N times", requeue_stuck), and so is alerting on it: a rule with the trigger job_finished (outcome timeout, requeued or gave_up) can raise an alert, send an email or call a webhook. A hook that moves cards races the server and can stall the runner.

    What to write — ask me before you start, then write it:

    1. Which notifier I use, if any: PushOver, ntfy, Slack, email, or something else, and where its credentials live (an environment variable or a file only I can read — never in the hook itself). Send an alert when a job times out or fails, with the card's link.
    2. What to keep from each job. For a Claude job, a record of the pass can be made from its Claude Code transcript: in the before-job hook, touch a marker file named after the job; in the after-job hook, take the newest .jsonl in the folder under ~/.claude/projects named after the job's working directory (every / and . turned into -) written since that marker that mentions $SLIPDOCK_CARD_URL. (Or have the job function pass claude a --session-id of its own and look that file up.) It can be summarised into a page on the board's wiki (`slipdock page new <board> <title> --file F`, then `slipdock page pin <page> --card $SLIPDOCK_CARD` so it shows under the card) or kept on disk. Ask me which, if any.
    3. A test script for the hooks, run against fake notify and pass-log commands and a folder of fake transcripts, that checks each status, a missing environment, a failing notifier and the exit code, and that the hooks never touch the board.

    A worked example to start from — one server's own hooks, with their test:

    #{base_url}/runner/examples/#{@example}
    #{base_url}/runner/examples/#{@example_test}

    #{wiring(windows?)}
    """
  end

  defp shape(false),
    do:
      "It is the shell runner, slipdock-runner; its config, ~/.config/slipdock-runner/config, is shell, and it calls the functions before_job and after_job, if the config defines them, around every job. Write the hooks as one script, ~/.local/bin/slipdock-hook, taking `before` or `after`, in bash or POSIX sh."

  defp shape(true),
    do:
      "It is the Windows runner, slipdock-runner.ps1; its config, %LOCALAPPDATA%\\slipdock-runner\\config.ps1, is PowerShell, and it calls the functions Before-Job and After-Job, if the config defines them, around every job. Write the hooks as one PowerShell script, slipdock-hook.ps1 beside the config, taking `before` or `after`. The example below is bash: translate it."

  defp env_list(windows?) do
    prefix = if windows?, do: "$env:", else: "$"

    lines =
      Enum.map(@env, fn {name, what, phase} ->
        "  - #{prefix}#{name}: #{what}#{if phase == :after, do: " (after-job only)", else: ""}"
      end)

    Enum.join(["- The runner sets these for both hooks:" | lines], "\n")
  end

  defp wiring(false),
    do:
      "When it's written and its test passes, show me the two lines for the runner's config — before_job() { ~/.local/bin/slipdock-hook before; } and after_job() { ~/.local/bin/slipdock-hook after; } — or the commands to type into the wizard's hook fields (Advanced → Hooks), and remind me that the hooks run as the runner's user, with its PATH."

  defp wiring(true),
    do:
      "When it's written and its test passes, show me the two functions for the runner's config — function Before-Job { & \"$PSScriptRoot\\slipdock-hook.ps1\" before } and function After-Job { & \"$PSScriptRoot\\slipdock-hook.ps1\" after } — or the commands to type into the wizard's hook fields (Advanced → Hooks), and remind me that the hooks run as the runner's user."
end
