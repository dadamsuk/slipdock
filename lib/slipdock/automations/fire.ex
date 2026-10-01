defmodule Slipdock.Automations.Fire do
  @moduledoc """
  A note that a rule has already acted on something, keyed by a string the
  runner derives from the card and the occasion (a due date, a card's last
  change, today's date). The unique index on `{rule_id, key}` is what stops
  a scheduled rule emailing you every minute.
  """
  use Ecto.Schema

  schema "automation_fires" do
    field :key, :string
    belongs_to :rule, Slipdock.Automations.Rule
    belongs_to :card, Slipdock.Boards.Card
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
