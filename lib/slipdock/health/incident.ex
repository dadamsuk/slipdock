defmodule Slipdock.Health.Incident do
  @moduledoc """
  One stuck state the health monitor found (see `Slipdock.Health`).

    * `detector` – the key of the detector that found it
    * `subject` – what it is about: `%{"card" => id, "job" => id, "runner" => id,
      "board" => id, "cards" => [id]}`, whichever apply
    * `fingerprint` – the detector, the subject and the state that made it an
      incident. Only one incident per fingerprint is active (open or flagged)
      at a time; a changed state is a new fingerprint
    * `summary` – what it is, in words
    * `data` – what the detector's fix needs to know
    * `status`:
      * `open` – found, and being fixed
      * `fixed` – a fix worked
      * `flagged` – no fix, or the fixes ran out: a person is told
      * `cleared` – the condition went by itself
      * `handled` – a person took the `stuck` flag off; that state is not
        flagged again
    * `attempts` – fixes tried so far
    * `log` – `[%{"at" => iso8601, "what" => text}]`, oldest first
  """
  use Ecto.Schema

  @statuses ~w(open fixed flagged cleared handled)
  @active ~w(open flagged)

  schema "health_incidents" do
    field :detector, :string
    field :fingerprint, :string
    field :subject, :map, default: %{}
    field :summary, :string
    field :data, :map, default: %{}
    field :status, :string, default: "open"
    field :attempts, :integer, default: 0
    field :log, {:array, :map}, default: []
    field :flagged_at, :utc_datetime
    field :resolved_at, :utc_datetime

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :alert, Slipdock.Automations.Alert

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def active_statuses, do: @active

  @doc "Whether it is still open or flagged."
  def active?(%__MODULE__{status: status}), do: status in @active

  @doc "Every card it is about: its own card first, then any others in its subject."
  def card_ids(%__MODULE__{card_id: card_id, subject: subject}) do
    Enum.uniq(Enum.reject([card_id | List.wrap(subject["cards"])], &is_nil/1))
  end
end
