defmodule Slipdock.Runners.Steering do
  @moduledoc """
  What a runner's agent is open to, said where a runner is set up (#3481):
  anyone who can write or comment on a board a runner serves gives its agent
  instructions, and the runner's executor and permission mode are what
  bound them, not the prompt.

  `notice/0` is the one text. The `machine add-runner` answer carries it
  (`notice`, which the CLI prints), and so do the machine's setup prompt
  (`Slipdock.Runners.MachineSetup`) and the Machines page. The manual's
  Runners and Machines pages say the same in their own words, and
  `test/slipdock/runner_steering_docs_test.exs` holds them to it.
  """

  @notice """
  Anyone who can write or comment on a board a runner serves can steer its agent. The card's text, its bar, its comments and its handoffs go into the agent's prompt, and the agent follows them as the account its jobs run as. The prompt tells it that card text is data, not instructions, but telling a model is not a limit. The limits are the runner's:

  - Executor: `me` stops nothing, so the agent can read and change whatever you can. `user` keeps it out of your home, `confined` stops it writing outside the job's directory, and `container` stops it reading or writing outside what is mounted, and the network when that is off.
  - Permission mode: `plan` changes nothing, `default` asks before an edit or a command, `acceptEdits` edits files without asking, and `bypassPermissions` runs any command without asking.

  Share a runner's board only with people you would let use this machine that way.
  """

  @doc "The notice, as Markdown (a paragraph, a two-item list and a line)."
  def notice, do: @notice
end
