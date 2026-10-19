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
    * `rollback` — the sha is an ancestor of the previous one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(started succeeded failed)
  @finished ~w(succeeded failed)
  @sources ~w(cli api backfill)

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

    belongs_to :board, Slipdock.Boards.Board

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def finished_statuses, do: @finished
  def sources, do: @sources

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
      :rollback
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
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_finished()
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
