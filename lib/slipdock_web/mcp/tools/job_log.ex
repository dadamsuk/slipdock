defmodule SlipdockWeb.MCP.Tools.JobLog do
  @moduledoc """
  A runner job's live log so far (#1871), as `slipdock job-log` prints it:
  one line per message, tool call or tool result of the job's agent, read
  from the transcript its runner sends about once a minute (#1870). `from`
  reads on from where an earlier call got to (its `next`), so an agent can
  watch a job by calling again. Anyone who can read the job's card can read
  its log.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Runners}
  alias Slipdock.Runners.{Job, Transcript, TranscriptView}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  # As read_page cuts a body: Claude's clients take about 150k characters.
  @max_text 100_000

  @impl true
  def name, do: "job_log"

  @impl true
  def title, do: "Read a runner job's live log"

  @impl true
  def description,
    do:
      "A runner job's log so far: one line per message, tool call or result of its agent, " <>
        "sent about once a minute while it runs. from: carry on from an earlier call's next. " <>
        "job.open: false once the job has ended."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        job: %{type: "integer", description: "The job's id (get_card's jobs, slipdock jobs)."},
        from: %{
          type: "integer",
          description: "The log line to start from: 0, or an earlier call's next."
        }
      },
      required: ["job"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    with {:ok, id} <- Args.id(args, "job"),
         {:ok, from} <- Args.offset(args, "from"),
         %Job{} = job <- Runners.get_job(id) || {:error, "no job you can see matches that"},
         %Slipdock.Boards.Card{} = card <-
           Boards.get_card(job.card_id) || {:error, "no job you can see matches that"},
         :ok <- Args.refusal(Authorize.card(Args.auth(context), card, :read)) do
      {lines, next} = lines(job, from)

      {:ok, job |> V.job_log(from, next) |> Map.put(:log, Enum.join(lines, "\n"))}
    end
  end

  # As many whole lines as fit, and where the next call starts: just past
  # the last transcript line shown, or the end when all of it fitted.
  defp lines(job, from) do
    entries = job |> Transcript.read(from) |> TranscriptView.entries(from)

    {kept, _} =
      Enum.reduce_while(entries, {[], 0}, fn e, {acc, size} ->
        line = TranscriptView.format(e)
        size = size + String.length(line) + 1

        if size > @max_text and acc != [],
          do: {:halt, {acc, size}},
          else: {:cont, {[{e, line} | acc], size}}
      end)

    kept = Enum.reverse(kept)
    cut? = length(kept) < length(entries)

    next =
      if cut?,
        do: elem(List.last(kept), 0).line + 1,
        else: max(job.transcript_lines, from)

    {Enum.map(kept, &elem(&1, 1)), next}
  end
end
