defmodule Slipdock.Runners.Runner do
  @moduledoc """
  A machine (or a Claude session) that takes jobs from one board tree's queue,
  for one pool. It authenticates with its own token — never an API token — so
  a runner can claim and report on jobs and do nothing else. Only the token's
  hash is kept; the token itself is shown once, when the runner is made.

  `settings` holds the setup wizard's answers so the config can be generated
  again. It never holds the token.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @name_format ~r/^[a-z0-9][a-z0-9_-]{0,39}$/

  schema "runners" do
    field :name, :string
    field :pool, :string
    field :token_hash, :binary, redact: true
    field :settings, :map, default: %{}
    field :last_seen_at, :utc_datetime
    field :current_job_id, :integer

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :created_by, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "What a pool or a job kind may be called: lower case, digits, `-` and `_`."
  def name_format, do: @name_format

  def changeset(runner, attrs) do
    runner
    |> cast(attrs, [:name, :pool, :settings])
    |> update_change(:pool, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :pool])
    |> validate_length(:name, max: 80)
    |> validate_format(:pool, @name_format,
      message: "must be lower case letters, digits, - or _ (at most 40)"
    )
  end
end
