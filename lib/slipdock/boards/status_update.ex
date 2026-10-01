defmodule Slipdock.Boards.StatusUpdate do
  @moduledoc """
  A stated health for a card or a wiki page: what its owner believes, as
  opposed to what the roll-up computes. On track, at risk or off track, with
  an optional note. The latest update is the thing's stated health.

  Exactly one of `card_id` and `page_id` is set; see `Slipdock.Boards.Owned`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @healths [
    {"on_track", "On track"},
    {"at_risk", "At risk"},
    {"off_track", "Off track"}
  ]

  schema "status_updates" do
    field :health, :string
    field :body, :string

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :user, Slipdock.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def healths, do: @healths
  def health_keys, do: Enum.map(@healths, &elem(&1, 0))

  def health_label(key) do
    case List.keyfind(@healths, key, 0) do
      {_, label} -> label
      nil -> key
    end
  end

  def changeset(update, attrs) do
    update
    |> cast(attrs, [:health, :body, :card_id, :page_id])
    |> update_change(:body, fn
      nil -> nil
      b -> b |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
    end)
    |> validate_required([:health])
    |> validate_inclusion(:health, health_keys())
    |> Slipdock.Boards.Owned.validate_owner()
    |> validate_length(:body, max: 4000)
  end
end
