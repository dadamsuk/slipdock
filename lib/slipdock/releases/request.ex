defmodule Slipdock.Releases.Request do
  @moduledoc """
  A release request on a root board (#2835): the tree's merged, unreleased
  cards going out together. At most one is `running` and one `queued` per
  board (two partial unique indexes), so releases run one at a time and a
  trigger that arrives during one joins the single follow-up.

  `queued` waits behind the running one; `running` has a runner job
  (`job_id`) firing or having fired the board's release command; it ends
  `released` (a deploy succeeded, or the command ran on a tree that records
  no deploys), `failed` (the command or the deploy failed) or `timed_out`
  (nothing was heard for `Slipdock.Releases.timeout_hours/0`).
  """
  use Ecto.Schema

  @open ~w(queued running)
  @ended ~w(released failed timed_out)
  @triggers ~w(critical manual age_cap)

  schema "release_requests" do
    field :status, :string, default: "queued"
    field :triggers, {:array, :map}, default: []
    field :card_ids, {:array, :integer}, default: []
    field :run_url, :string
    field :note, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :job, Slipdock.Runners.Job

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The statuses of a request that hasn't ended: `queued`, `running`."
  def open_statuses, do: @open

  @doc "The statuses a request ends in: `released`, `failed`, `timed_out`."
  def ended_statuses, do: @ended

  @doc "What can ask for a release: `critical`, `manual`, `age_cap`."
  def triggers, do: @triggers
end
