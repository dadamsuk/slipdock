defmodule SlipdockWeb.MCP.Tools.FinishJob do
  @moduledoc "Ends a job taken with `claim_job`."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Runners
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @outcomes ~w(done failed cancelled timeout waiting)

  @impl true
  def name, do: "finish_job"

  @impl true
  def title, do: "Finish a runner job"

  @impl true
  def description,
    do:
      "Ends a job you took with claim_job: outcome done, failed, cancelled or timeout, " <>
        "and a one-paragraph summary kept on the job. Close the card itself as usual."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        job: %{type: "integer"},
        outcome: %{
          type: "string",
          enum: @outcomes,
          description:
            "waiting, with wait, asks a person and parks the job; the answer starts a fresh one."
        },
        summary: %{type: "string"},
        wait: %{
          type: "object",
          description: "With outcome waiting: the question, as update_card's wait.",
          properties: %{
            needs: %{type: "string"},
            on: %{type: "string"},
            choices: %{type: "array", items: %{type: "string"}}
          },
          required: ["needs"],
          additionalProperties: false
        }
      },
      required: ["job", "outcome"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    with {:ok, job, card, runner} <- session_job(args, context),
         {:ok, outcome} <- Args.required(args, "outcome"),
         :ok <- outcome(outcome),
         {:ok, summary} <- Args.optional(args, "summary") do
      if outcome == "waiting",
        do: park(job, card, runner, args, summary, context),
        else: finish(job, runner, outcome, summary)
    end
  end

  # Asks and parks in one step: both, or neither (KTD5).
  defp park(job, card, runner, args, summary, context) do
    with %{} = wait <- args["wait"] || {:error, "outcome waiting needs wait: {needs: \"…\"}"},
         {:ok, job, wait} <-
           Args.refusal(
             Runners.finish_waiting(
               runner,
               job.id,
               fn job ->
                 Args.auth(context)
                 |> CardWrites.open_wait(card, Map.put(wait, "job_id", job.id))
                 |> Args.refusal()
               end,
               %{output: summary}
             )
             |> lapsed(job)
           ) do
      {:ok, %{job: job.id, status: job.status, wait: V.wait(wait)}}
    end
  end

  defp lapsed({:error, :not_found}, job),
    do: {:error, "job ##{job.id} wasn't claimed with this token: its lease may have run out"}

  defp lapsed(result, _job), do: result

  defp finish(job, runner, outcome, summary) do
    with {:ok, job} <-
           Args.refusal(
             Runners.finish(runner, job.id, %{
               status: outcome,
               exit: if(outcome == "done", do: 0, else: 1),
               output: summary
             })
           ) do
      {:ok, %{job: job.id, status: job.status}}
    end
  end

  defp outcome(outcome) when outcome in @outcomes, do: :ok
  defp outcome(_), do: {:error, "outcome must be one of #{Enum.join(@outcomes, ", ")}"}

  @doc false
  # The job `args` names, its card (which the token must be able to edit) and
  # the session runner this token claimed it through. Shared with
  # `job_progress`.
  def session_job(args, context) do
    with {:ok, id} <- job_id(args),
         %{} = job <- Runners.get_job(id) || {:error, "no job ##{id}"},
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(job.card_id)),
         :ok <- Args.refusal(Authorize.card(Args.auth(context), card, :write)),
         {:ok, runner} <- session_runner(job, context) do
      {:ok, job, card, runner}
    end
  end

  defp job_id(args) do
    case Args.id(args, "job") do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, "job must be a job number, from claim_job"}
    end
  end

  defp session_runner(job, context) do
    case Runners.session_job_runner(job.id, context.token) do
      {:ok, runner} -> {:ok, runner}
      {:error, :not_found} -> {:error, "job ##{job.id} wasn't claimed with this token"}
    end
  end
end
