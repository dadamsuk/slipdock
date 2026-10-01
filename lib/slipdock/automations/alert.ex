defmodule Slipdock.Automations.Alert do
  @moduledoc """
  Something a rule wants the reader to notice: shown in the header bar of
  every page until each person dismisses it (see
  `Slipdock.Automations.Dismissal`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @severities ~w(info warning urgent)

  schema "alerts" do
    field :title, :string
    field :body, :string
    field :severity, :string, default: "info"

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :rule, Slipdock.Automations.Rule

    has_many :dismissals, Slipdock.Automations.Dismissal

    timestamps(type: :utc_datetime)
  end

  def severities, do: @severities

  @doc "The heroicon name for a severity."
  def icon("urgent"), do: "hero-exclamation-triangle"
  def icon("warning"), do: "hero-exclamation-circle"
  def icon(_), do: "hero-information-circle"

  def changeset(alert, attrs) do
    alert
    |> cast(attrs, [:title, :body, :severity, :board_id, :card_id, :rule_id])
    |> validate_required([:title, :board_id])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_inclusion(:severity, @severities)
  end
end
