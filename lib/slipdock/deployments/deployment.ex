defmodule Slipdock.Deployments.Deployment do
  @moduledoc """
  One deploy of a board's project to an environment (#1134): a ledger row,
  not a card. Machine-written by CI through `Slipdock.Deployments`, and
  never edited once it has finished.

    * `status` — `started`, then `succeeded` or `failed`;
    * `sha` / `tag` — what was deployed; `previous_sha` the environment's
      last succeeded deploy when this one started, which the commits run
      from;
    * `commits` — `[%{"sha", "committed_at", "subject", "cards"}]`, newest
      first, as `git log` gives them; `card_ids` is every card they name,
      on the board's own tree only;
    * `source` — `cli`, `api` or `backfill`;
    * `rollback` — the sha is an ancestor of the previous one;
    * `note` — a line from CI about this deploy (#1857), such as how its
      suite was satisfied: `suite: ran`, or passed on the pull request at
      the same tree;
    * `stage` — where a failed attempt failed (#2820): `build`, `test` or
      `merge` (it never reached the environment, so it isn't a deploy to
      DORA: see `pre_deploy_stages/0`), `deploy` or `health`;
    * `run_url` — the CI run that made the attempt.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(started succeeded failed)
  @finished ~w(succeeded failed)
  @sources ~w(cli api backfill)
  @stages ~w(build test merge deploy health)
  @pre_deploy ~w(build test merge)

  schema "deployments" do
    field :environment, :string
    field :sha, :string
    field :tag, :string
    field :previous_sha, :string
    field :status, :string, default: "started"
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :source, :string, default: "api"
    field :commits, {:array, :map}, default: []
    field :card_ids, {:array, :integer}, default: []
    field :rollback, :boolean, default: false
    field :note, :string
    field :stage, :string
    field :run_url, :string

    belongs_to :board, Slipdock.Boards.Board

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def finished_statuses, do: @finished
  def sources, do: @sources

  @doc "Where a release can fail (#2820), in the order it runs them."
  def stages, do: @stages

  @doc "The stages before anything reaches the environment: a failure there is no deploy."
  def pre_deploy_stages, do: @pre_deploy

  @doc "Whether `deployment` is a failure before it reached the environment."
  def pre_deploy?(%__MODULE__{status: "failed", stage: stage}),
    do: Enum.member?(@pre_deploy, stage)

  def pre_deploy?(_deployment), do: false

  @env_format ~r/^[A-Za-z0-9][A-Za-z0-9._\/-]{0,59}$/
  @sha_format ~r/^[0-9a-f]{7,64}$/

  @doc "A new deploy: `started`, or already finished when a status says so (a backfill)."
  def start_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :environment,
      :sha,
      :tag,
      :previous_sha,
      :status,
      :started_at,
      :finished_at,
      :source,
      :commits,
      :card_ids,
      :rollback,
      :note,
      :stage,
      :run_url
    ])
    |> update_change(:sha, &String.downcase/1)
    |> update_change(:previous_sha, &String.downcase/1)
    |> validate_required([:environment, :sha, :status, :started_at, :source])
    |> validate_format(:environment, @env_format,
      message: "must be letters, digits, dots, slashes, hyphens or underscores (up to 60)"
    )
    |> validate_format(:sha, @sha_format, message: "must be a hex commit sha")
    |> validate_format(:previous_sha, @sha_format, message: "must be a hex commit sha")
    |> validate_length(:tag, max: 200)
    |> validate_length(:note, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_stage()
    |> validate_finished()
  end

  @doc """
  A failed attempt as `Slipdock.Deployments.record_failure/2` takes it:
  the start changeset, with a stage required.
  """
  def failure_changeset(deployment, attrs) do
    deployment
    |> start_changeset(attrs)
    |> validate_required([:stage], message: "is required: one of #{Enum.join(@stages, ", ")}")
  end

  @doc """
  The deploy job's own record of an attempt, finished as failed at `stage`
  (#2820): a started one is finished here; a failed one with no stage yet
  is told where it failed. Nothing else about it changes.
  """
  def fail_changeset(%__MODULE__{status: status, stage: nil} = deployment, attrs, at)
      when status in ["started", "failed"] do
    deployment
    |> cast(attrs, [:stage, :run_url])
    |> validate_required([:stage])
    |> validate_stage()
    |> put_change(:status, "failed")
    |> put_change(:finished_at, deployment.finished_at || at)
  end

  # A run link is a web address, and a stage one of the release's.
  defp validate_stage(changeset) do
    changeset
    |> validate_inclusion(:stage, @stages, message: "must be one of #{Enum.join(@stages, ", ")}")
    |> validate_length(:run_url, max: 500)
    |> validate_format(:run_url, ~r{^https?://[^\s]+$}, message: "must be an http(s) URL")
  end

  @doc "Finishing a started deploy: `succeeded` or `failed`, once."
  def finish_changeset(%__MODULE__{status: "started"} = deployment, status, at)
      when status in @finished,
      do: change(deployment, status: status, finished_at: at)

  def finish_changeset(%__MODULE__{status: "started"} = deployment, _status, _at),
    do: deployment |> change() |> add_error(:status, "must be succeeded or failed")

  def finish_changeset(%__MODULE__{} = deployment, _status, _at) do
    deployment
    |> change()
    |> add_error(:status, "is already #{deployment.status}: a deploy finishes once")
  end

  # A row that arrives finished carries when it finished; a started one doesn't.
  defp validate_finished(changeset) do
    case get_field(changeset, :status) do
      "started" ->
        put_change(changeset, :finished_at, nil)

      status when status in @finished ->
        if get_field(changeset, :finished_at),
          do: changeset,
          else: put_change(changeset, :finished_at, get_field(changeset, :started_at))

      _ ->
        changeset
    end
  end
end
