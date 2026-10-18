defmodule Slipdock.Recurrence.Series do
  @moduledoc """
  A recurring card's series (W-1802), the `card_recurrences` table: the rule,
  where and when its instances are made, and the next one.

  `card_id` is the current instance, the one the next is copied from; it
  moves on to each new instance. `next_on` is the date the next instance is
  due, `next_at` the UTC moment it is made (`lead_days` before `next_on`, at
  `create_at` in `timezone`). An after-done series has no `next_at` until its
  current instance is completed.

  `made` counts the instances so far, the first card included, which is what
  `ends: "after"` with `count` compares against.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Slipdock.Recurrence.Rule

  @on_missed ~w(bump skip stack)
  @ends ~w(never on after)
  @max_lead_days 365

  schema "card_recurrences" do
    field :kind, :string, default: "fixed"
    field :rule, :string
    field :starts_on, :date
    field :create_at, :time, default: ~T[07:00:00]
    field :timezone, :string, default: "Etc/UTC"
    field :lead_days, :integer, default: 0
    field :on_missed, :string, default: "bump"
    field :ends, :string, default: "never"
    field :ends_on, :date
    field :count, :integer
    field :made, :integer, default: 1
    field :next_on, :date
    field :next_at, :utc_datetime
    field :paused, :boolean, default: false
    field :ended_at, :utc_datetime

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :column, Slipdock.Boards.Column
    belongs_to :last_created_card, Slipdock.Boards.Card
    belongs_to :created_by, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def on_missed_options, do: @on_missed
  def ends_options, do: @ends

  @doc """
  What a person may set: the rule (already read into stored form), when and
  where instances are made, what happens to a missed one, and when it ends.
  """
  def changeset(series, attrs) do
    series
    |> cast(attrs, [
      :rule,
      :starts_on,
      :create_at,
      :timezone,
      :lead_days,
      :column_id,
      :on_missed,
      :ends,
      :ends_on,
      :count,
      :paused
    ])
    |> validate_required([:rule, :starts_on, :create_at, :timezone])
    |> validate_rule()
    |> validate_change(:timezone, fn :timezone, tz ->
      if Slipdock.Timezones.valid?(tz),
        do: [],
        else: [timezone: "isn't a timezone this server knows"]
    end)
    |> validate_number(:lead_days,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_lead_days
    )
    |> validate_inclusion(:on_missed, @on_missed, message: "must be bump, skip or stack")
    |> validate_inclusion(:ends, @ends, message: "must be never, on or after")
    |> validate_ends()
  end

  defp validate_rule(changeset) do
    case get_field(changeset, :rule) do
      nil ->
        changeset

      text ->
        case Rule.parse(text) do
          {:ok, rule} ->
            changeset
            |> put_change(:rule, Rule.to_string(rule))
            |> put_change(:kind, Atom.to_string(rule.kind))

          {:error, message} ->
            add_error(changeset, :rule, message)
        end
    end
  end

  defp validate_ends(changeset) do
    case get_field(changeset, :ends) do
      "on" ->
        changeset
        |> validate_required([:ends_on], message: "say the date it ends on")
        |> put_change(:count, nil)

      "after" ->
        changeset
        |> validate_required([:count], message: "say how many times")
        |> validate_number(:count, greater_than_or_equal_to: 1, less_than_or_equal_to: 1000)
        |> put_change(:ends_on, nil)

      _ ->
        changeset |> put_change(:ends_on, nil) |> put_change(:count, nil)
    end
  end

  @doc "The rule, read, counting from the series' start."
  def rule(%__MODULE__{rule: text, starts_on: start}) do
    {:ok, rule} = Rule.parse(text, start)
    rule
  end

  @doc "The series' end as `Rule.within_end?/3` takes it."
  def ending(%__MODULE__{ends: "on", ends_on: %Date{} = d}), do: {"on", d}
  def ending(%__MODULE__{ends: "after", count: n}) when is_integer(n), do: {"after", n}
  def ending(_), do: "never"

  @doc "Whether the series still makes instances: not paused, not ended."
  def active?(%__MODULE__{paused: false, ended_at: nil}), do: true
  def active?(_), do: false

  @doc "In words: \"Every Mon, 07:00 Europe/London\"."
  def summary(%__MODULE__{} = s), do: Rule.summary(rule(s), s.create_at, s.timezone)
end
