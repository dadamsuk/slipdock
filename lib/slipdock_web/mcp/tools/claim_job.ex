defmodule SlipdockWeb.MCP.Tools.ClaimJob do
  @moduledoc """
  Takes the next runner job of a pool, so a Claude session works the same
  queue as the shell runners rather than racing them for the same card (see
  `Slipdock.Runners`).
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Runners
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "claim_job"

  @impl true
  def title, do: "Take a runner job"

  @impl true
  def description,
    do:
      "Takes the oldest job queued for a runner pool on a board, with a lease. Work the " <>
        "card it names, report with job_progress between steps (the lease is 20 min; stop if it says " <>
        "cancel), end with finish_job. Answers \"nothing queued\" when there is none."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        pool: %{type: "string", description: "The runner pool, e.g. default."}
      },
      required: ["board", "pool"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, pool} <- Args.required(args, "pool"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :write)),
         {:ok, runner} <-
           Args.refusal(Runners.session_runner(board, pool, context.token, context.user)) do
      case Runners.claim(runner) do
        # Every idle poll is a model call: the empty answer is kept tiny.
        nil ->
          case Runners.first_waiting(board, runner.pool) do
            nil ->
              {:ok, "nothing queued"}

            job ->
              {:ok,
               "nothing queued to take: job ##{job.id} waits while " <>
                 "#{Runners.waiting_reason(job)}"}
          end

        job ->
          {:ok,
           %{
             job: job.id,
             kind: job.kind,
             card: job.card_id,
             card_url: context.base_url <> "/boards/#{job.board_id}/cards/#{job.card_id}",
             lease_seconds: Runners.lease_for(runner),
             prompt: job.prompt
           }}
      end
    end
  end
end
