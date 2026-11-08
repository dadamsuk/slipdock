defmodule Slipdock.Overseer.Condition do
  @moduledoc """
  Something a watch check found (#2068), open from when it first did until
  the check stops finding it: then it is cleared, and its alert taken down.
  One open row per root board, check and subject, so a condition fires once
  however many times it is seen.

  `subject` names what it is about (`card:12`, `pool:default`,
  `lane:34`); `card_id` is the card a person should open, which is also
  what puts it in their *Waiting on you*. `why` says what was seen and
  `todo` what to do about it.
  """
  use Ecto.Schema

  schema "overseer_conditions" do
    field :check, :string
    field :subject, :string
    field :severity, :string, default: "warning"
    field :title, :string
    field :why, :string
    field :todo, :string
    field :opened_at, :utc_datetime
    field :cleared_at, :utc_datetime

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :alert, Slipdock.Automations.Alert

    timestamps(type: :utc_datetime)
  end

  @doc "Whether it is still open."
  def open?(%__MODULE__{cleared_at: nil}), do: true
  def open?(%__MODULE__{}), do: false
end
