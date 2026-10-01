defmodule Slipdock.Automations.Rule do
  @moduledoc """
  One automation rule: the sentence the user wrote (`source`), the parsed
  `spec` (see `Slipdock.Automations.Spec`) and how it has been getting on.

  `scope` decides which cards the rule watches: "board" only the cards on
  the board it belongs to, "tree" every card on that board and the
  sub-boards beneath it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Slipdock.Automations.Spec

  @scopes ~w(board tree)

  schema "automation_rules" do
    field :name, :string
    field :source, :string
    field :spec, :map
    field :scope, :string, default: "board"
    field :enabled, :boolean, default: true
    field :run_count, :integer, default: 0
    field :last_run_at, :utc_datetime
    field :last_error, :string

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :created_by, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def scopes, do: @scopes

  @doc "Whether the rule waits for a clock rather than an event."
  def scheduled?(%__MODULE__{spec: spec}), do: Spec.scheduled?(spec)

  @doc "The rule's trigger type, as a string."
  def trigger_type(%__MODULE__{spec: spec}), do: Spec.trigger_type(spec)

  @doc "A sentence describing what the rule does, built from the spec."
  def summary(%__MODULE__{spec: spec}), do: Spec.summary(spec)

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:name, :source, :spec, :scope, :enabled, :board_id])
    |> validate_required([:name, :spec, :board_id])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_inclusion(:scope, @scopes)
    |> validate_spec()
  end

  # The spec is the rule: an invalid one would fail silently at run time, so
  # it is checked (and normalised) on the way in.
  defp validate_spec(changeset) do
    case get_change(changeset, :spec) do
      nil ->
        changeset

      spec ->
        case Spec.validate(spec) do
          {:ok, normalised} -> put_change(changeset, :spec, normalised)
          {:error, message} -> add_error(changeset, :spec, message)
        end
    end
  end
end
