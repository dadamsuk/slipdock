defmodule Slipdock.Runners.Job do
  @moduledoc """
  One card sent to a pool of runners: what to run (`kind`, which the runner
  looks up in its own config) and the text to give it (`prompt`, rendered
  when the job was queued). The server never says *how* a kind is run.

      queued → claimed → running → done | failed | cancelled | timeout | parked

  A job whose agent asked a person something — a wait opened from the job
  (`Slipdock.Boards.open_wait/3` with its `job_id`) and still open when it
  ends — ends `parked`, whatever its exit code, and never comes back by
  itself: answering the wait queues a fresh one (`Slipdock.Runners.Requeue`).

  A job with `wait_while_doing` stays queued, and is not handed out, while
  any other open card is in a doing list on its board (see
  `Slipdock.Runners.waiting_on/1`).

  A job from a `list_top` rule with `requeue_stuck` that ends with its card
  still in a doing list puts the card back on its list, or gives up on it
  (see `Slipdock.Runners.Recovery`).

  A claim comes with a lease; heartbeats extend it. A lease that runs out
  puts the job back in the queue, up to a retry cap (see
  `Slipdock.Runners.sweep/1`).
  """
  use Ecto.Schema

  @statuses ~w(queued claimed running done failed cancelled timeout parked)
  @open ~w(queued claimed running)
  @finished ~w(done failed cancelled timeout parked)

  schema "runner_jobs" do
    field :pool, :string
    # A runner that may not take this job (#1625): for a verify job, the one
    # that built the card.
    field :exclude_runner_id, :integer
    # More runners that may not take it (#1780): an audit excludes the
    # card's builder and the runner that verified it.
    field :exclude_runner_ids, {:array, :integer}, default: []
    # A verify job that re-checks an accepted card (#1780): it comments and
    # says whether it agrees, and never changes the card.
    field :audit, :boolean, default: false
    field :kind, :string
    field :prompt, :string
    field :status, :string, default: "queued"
    field :attempts, :integer, default: 0
    # Copied from the rule's runner action when queued: claim passes the job
    # over while another open card sits in a doing list on its board.
    field :wait_while_doing, :boolean, default: false
    # Set when the job ended with its card still in progress and its rule
    # puts such cards back: "requeued" or "gave_up" ("requeued_before_done"
    # once the card has been completed since; see `Slipdock.Runners.Recovery`),
    # or "parked" when a parked job's card was put back on its rule's list.
    field :recovery, :string
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
    # A merge job (#1656): the commit the pull request was merged as, as
    # the runner reported it (`finish?merged=<sha>`).
    field :merged_sha, :string
    # The latest progress message its agent gave (#1668: `job-progress
    # --step`, MCP `job_progress` `step`), and when: shown against the job,
    # never posted on the card.
    field :step, :string
    field :step_at, :utc_datetime
    # Its live log (#1870): the agent's transcript, sent by the runner as it
    # goes and kept in chunks (see `Slipdock.Runners.Transcript`). Lines are
    # the runner's count, so a resend is trimmed; capped once the whole-log
    # limit was hit.
    field :transcript_lines, :integer, default: 0
    field :transcript_bytes, :integer, default: 0
    field :transcript_capped, :boolean, default: false
    field :transcript_at, :utc_datetime

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
