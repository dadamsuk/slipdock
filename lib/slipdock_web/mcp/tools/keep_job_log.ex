defmodule SlipdockWeb.MCP.Tools.KeepJobLog do
  @moduledoc """
  Keep this log (#1872), over MCP: writes an ended runner job's live log as
  a page in its card's folder, `Pass <card> (<date>)`, links it from the job
  and stops the log expiring. Keeping it again answers the same page. Needs
  write access to the card.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Runners}
  alias Slipdock.Runners.{Job, TranscriptRetention}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "keep_job_log"

  @impl true
  def title, do: "Keep a runner job's log"

  @impl true
  def description,
    do:
      "Keeps an ended runner job's live log, which otherwise expires: writes it as a page " <>
        "Pass <card> (<date>) in the card's folder and links it from the job. Again gives " <>
        "the same page."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        job: %{type: "integer", description: "The job's id (get_card's jobs, slipdock jobs)."}
      },
      required: ["job"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    with {:ok, id} <- Args.id(args, "job"),
         %Job{} = job <- Runners.get_job(id) || {:error, "no job you can see matches that"},
         %Boards.Card{} = card <-
           Boards.Cards.get_card(job.card_id) || {:error, "no job you can see matches that"},
         :ok <- Args.refusal(Authorize.card(Args.auth(context), card, :write)),
         {:ok, page, job} <- kept(TranscriptRetention.keep(job, context.user, via: "mcp")) do
      {:ok,
       job
       |> V.job_log(0, job.transcript_lines)
       |> Map.put(:page, %{id: page.id, code: page.code, title: page.title})}
    end
  end

  defp kept({:ok, page, job}), do: {:ok, page, job}

  defp kept({:error, {:payment_required, code, message}}),
    do: Args.refusal({:error, :payment_required, code, message})

  defp kept({:error, reason}), do: {:error, TranscriptRetention.refusal(reason)}
end
