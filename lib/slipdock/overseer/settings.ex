defmodule Slipdock.Overseer.Settings do
  @moduledoc """
  The overseer's settings for one root board (#2068): whether it is on,
  the runner pool its passes go to, the bounds its pacing keeps between
  (`min_minutes` while cards are active, `max_minutes` when nothing is in
  flight), how long runners sit idle before the watch says so, and whether
  a condition is emailed to the owner as well as raised as an alert.

  `digest_at` is when the morning digest of Housekeeping's work is written
  (#2781, `Slipdock.Overseer.Housekeeping`).

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
    # The morning digest of Housekeeping's work (#2781): when it is written
    # ("HH:MM" in the owner's zone), and when it last was.
    field :digest_at, :string, default: "07:00"
    field :housekeeping_digest_on, :date
    field :housekeeping_digest_at, :utc_datetime

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :last_job, Slipdock.Runners.Job

    timestamps(type: :utc_datetime)
  end

  @doc "The fewest and most minutes a pass may be set apart."
  def bounds, do: {@floor, @ceiling}

  @doc "The fields a person may set."
  def fields, do: ~w(enabled pool min_minutes max_minutes idle_minutes email digest_at)a

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, fields())
    |> update_change(:pool, &(&1 |> trim() |> downcase()))
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
    |> validate_digest_at()
  end

  # "HH:MM", a time of day (#2781), stored zero-padded so what is shown
  # back is what `digest_time/1` reads.
  defp validate_digest_at(changeset) do
    changeset
    |> update_change(:digest_at, &trim/1)
    |> validate_required([:digest_at])
    |> validate_change(:digest_at, fn :digest_at, at ->
      case digest_time(at) do
        {:ok, _} -> []
        :error -> [digest_at: "must be a time of day, HH:MM"]
      end
    end)
    |> update_change(:digest_at, fn at ->
      case digest_time(at) do
        {:ok, time} -> Calendar.strftime(time, "%H:%M")
        :error -> at
      end
    end)
  end

  @doc """
  The time of day a `digest_at` names: `{:ok, time}` for `H:MM` or
  `HH:MM` within a day, else `:error`.
  """
  def digest_time(at) when is_binary(at) do
    with [_, h, m] <- Regex.run(~r/^(\d{1,2}):(\d{2})$/, at),
         {h, ""} when h in 0..23 <- Integer.parse(h),
         {m, ""} when m in 0..59 <- Integer.parse(m) do
      Time.new(h, m, 0)
    else
      _ -> :error
    end
  end

  def digest_time(_at), do: :error

  # A field sent as null is left for validate_required to refuse, not
  # handed to String functions.
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(value), do: value

  defp validate_bounds(changeset) do
    min = get_field(changeset, :min_minutes)
    max = get_field(changeset, :max_minutes)

    if is_integer(min) and is_integer(max) and min > max,
      do: add_error(changeset, :max_minutes, "must be at least min_minutes (#{min})"),
      else: changeset
  end
end
