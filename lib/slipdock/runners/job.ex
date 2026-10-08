defmodule Slipdock.Runners.Job do
  @moduledoc """
  One card sent to a pool of runners: what to run (`kind`, which the runner
  looks up in its own config) and the text to give it (`prompt`, rendered
  when the job was queued). The server never says *how* a kind is run.

      queued → claimed → running → done | failed | cancelled | timeout

  A job with `wait_while_doing` stays queued, and is not handed out, while
  any other open card is in a doing list on its board (see
  `Slipdock.Runners.waiting_on/1`).

  A claim comes with a lease; heartbeats extend it. A lease that runs out
  puts the job back in the queue, up to a retry cap (see
  `Slipdock.Runners.sweep/1`).
  """
  use Ecto.Schema

  @statuses ~w(queued claimed running done failed cancelled timeout)
  @open ~w(queued claimed running)
  @finished ~w(done failed cancelled timeout)

  schema "runner_jobs" do
    field :pool, :string
    field :kind, :string
    field :prompt, :string
    field :status, :string, default: "queued"
    field :attempts, :integer, default: 0
    # Copied from the rule's runner action when queued: claim passes the job
    # over while another open card sits in a doing list on its board.
    field :wait_while_doing, :boolean, default: false
    field :runner_name, :string
    field :lease_expires_at, :utc_datetime
    field :cancel_requested_at, :utc_datetime
    field :exit_code, :integer
    field :log_tail, :string
    field :output, :string
    field :error, :string
    field :claimed_at, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :root_board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :rule, Slipdock.Automations.Rule
    belongs_to :runner, Slipdock.Runners.Runner

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def open_statuses, do: @open
  def finished_statuses, do: @finished

  @doc "Whether the job is still waiting or being worked."
  def open?(%__MODULE__{status: status}), do: status in @open
end
