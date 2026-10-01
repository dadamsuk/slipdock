defmodule Slipdock.Boards.CardLink do
  @moduledoc """
  A typed link from one card to another, on any board:

    * `relates` – related work (shown both ways)
    * `contributes` – the card contributes to a goal card, which collects
      its contributions and their progress
    * `duplicates` – the card duplicates the other

  Blocking dependencies stay in `card_dependencies`; they carry scheduling
  semantics these links don't.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds [
    {"relates", "Relates to", "Related to"},
    {"contributes", "Contributes to", "Contributions"},
    {"duplicates", "Duplicates", "Duplicated by"}
  ]

  schema "card_links" do
    field :kind, :string
    belongs_to :from, Slipdock.Boards.Card
    belongs_to :to, Slipdock.Boards.Card
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Kinds as `{key, label_from_the_source, label_from_the_target}`."
  def kinds, do: @kinds
  def kind_keys, do: Enum.map(@kinds, &elem(&1, 0))

  def label(kind, :out), do: find(kind) |> elem(1)
  def label(kind, :in), do: find(kind) |> elem(2)

  defp find(kind), do: Enum.find(@kinds, {kind, kind, kind}, &(elem(&1, 0) == kind))

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:kind])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, kind_keys())
    |> unique_constraint([:from_id, :to_id, :kind], message: "already linked")
  end
end
