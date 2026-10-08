defmodule SlipdockWeb.MCP.Tools.JobProgress do
  @moduledoc "A heartbeat for a job taken with `claim_job`, with an optional comment on its card."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Runners}
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.FinishJob

  @impl true
  def name, do: "job_progress"

  @impl true
  def title, do: "Report on a runner job"

  @impl true
  def description,
    do:
      "Renews a claimed job's lease; note, if given, is also posted as a comment on the " <>
        "card. Answers ok, or cancel: then stop and finish_job with outcome cancelled."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{job: %{type: "integer"}, note: %{type: "string"}},
      required: ["job"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    with {:ok, job, card, runner} <- FinishJob.session_job(args, context),
         {:ok, note} <- Args.optional(args, "note"),
         {:ok, answer} <- Args.refusal(Runners.heartbeat(runner, job.id, note)) do
      if note, do: Boards.add_comment(card, note, by: context.user)
      {:ok, %{job: job.id, status: to_string(answer)}}
    end
  end
end
