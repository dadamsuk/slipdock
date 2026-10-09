defmodule Slipdock.Meetings.Voice do
  @moduledoc """
  One speaker in a capture: a voice the diariser separated, or a label the
  transcript carried, and who it is believed to be — a person here (`user`),
  or only a `name` — with the `evidence` for that belief, each item kept so it
  can be shown. `merged_into` records an over-split voice folded into another.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "capture_voices" do
    belongs_to :capture, Slipdock.Meetings.Capture
    field :label, :string
    field :name, :string
    belongs_to :user, Slipdock.Accounts.User
    field :evidence, {:array, :map}, default: []
    field :confidence, :string, default: "unknown"
    belongs_to :confirmed_by, Slipdock.Accounts.User
    field :confirmed_at, :utc_datetime
    belongs_to :merged_into, __MODULE__
    timestamps(type: :utc_datetime)
  end

  def changeset(voice, attrs) do
    voice
    |> cast(attrs, [:label, :name, :user_id, :evidence, :merged_into_id, :confidence])
    |> validate_required([:label])
  end
end
