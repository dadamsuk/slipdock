defmodule Slipdock.Overseer.Settings do
  @moduledoc """
  The overseer's settings for one root board (#2068): whether it is on,
  the runner pool its passes go to, the bounds its pacing keeps between
  (`min_minutes` while cards are active, `max_minutes` when nothing is in
  flight), how long runners sit idle before the watch says so, and whether
  a condition is emailed to the owner as well as raised as an alert.

  It also keeps where the overseer stands: its card (the completed card on
  the root board its jobs hang off, whose status updates are the digests),
  when its next pass is due, and the last digest.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @floor 5
  @ceiling 24 * 60

  schema "overseer_settings" do
    field :enabled, :boolean, default: false
    field :pool, :string, default: "default"
    field :min_minutes, :integer, default: 10
    field :max_minutes, :integer, default: 120
    field :idle_minutes, :integer, default: 15
    field :email, :boolean, default: true
    field :next_run_at, :utc_datetime
    field :last_queued_at, :utc_datetime
    field :last_digest, :string
    field :last_health, :string
    field :last_digest_at, :utc_datetime
    field :watched_at, :utc_datetime

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :last_job, Slipdock.Runners.Job

    timestamps(type: :utc_datetime)
  end

  @doc "The fewest and most minutes a pass may be set apart."
  def bounds, do: {@floor, @ceiling}

  @doc "The fields a person may set."
  def fields, do: ~w(enabled pool min_minutes max_minutes idle_minutes email)a

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, fields())
    |> update_change(:pool, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:pool, :min_minutes, :max_minutes, :idle_minutes])
    |> validate_format(:pool, Slipdock.Runners.Runner.name_format(),
      message: "must be lower case letters, digits, - or _"
    )
    |> validate_number(:min_minutes,
      greater_than_or_equal_to: @floor,
      less_than_or_equal_to: @ceiling
    )
    |> validate_number(:max_minutes,
      greater_than_or_equal_to: @floor,
      less_than_or_equal_to: @ceiling
    )
    |> validate_number(:idle_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @ceiling
    )
    |> validate_bounds()
  end

  defp validate_bounds(changeset) do
    min = get_field(changeset, :min_minutes)
    max = get_field(changeset, :max_minutes)

    if is_integer(min) and is_integer(max) and min > max,
      do: add_error(changeset, :max_minutes, "must be at least min_minutes (#{min})"),
      else: changeset
  end
end
