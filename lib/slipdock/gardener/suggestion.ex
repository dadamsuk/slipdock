defmodule Slipdock.Gardener.Suggestion do
  @moduledoc """
  One thing the gardener found and the fix it proposes (W-1807).

    * `subject` – what it is about: `%{"cards" => [id], "pages" => [id]}`
    * `fingerprint` – the check, the subjects and the state that made it a
      finding. A dismissed or applied fingerprint is never suggested again;
      when the subject changes, so does the fingerprint
    * `proposal` – the steps applying it takes (see `Slipdock.Gardener.Steps`)
    * `alternatives` – other fixes the person may choose instead, by name
    * `explanation` – a sentence with the evidence
    * `state` – `open`, `applied`, `dismissed`, or `expired` (a later run no
      longer found it)
    * `undo` – once applied, the inverse steps and the state each subject
      was left in, so undo can tell when something has moved on since
  """
  use Ecto.Schema

  @states ~w(open applied dismissed expired)

  schema "garden_suggestions" do
    field :check, :string
    field :subject, :map, default: %{}
    field :fingerprint, :string
    field :proposal, {:array, :map}, default: []
    field :alternatives, :map, default: %{}
    field :explanation, :string
    field :state, :string, default: "open"
    field :decided_at, :utc_datetime
    field :undo, :map

    belongs_to :run, Slipdock.Gardener.Run
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :decided_by, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  @doc "The card ids it is about."
  def card_ids(%__MODULE__{subject: subject}), do: Map.get(subject, "cards", [])

  @doc "The page ids it is about."
  def page_ids(%__MODULE__{subject: subject}), do: Map.get(subject, "pages", [])
end
