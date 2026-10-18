defmodule Slipdock.Boards.Handoff do
  @moduledoc """
  Where a card was left: the one next step, and a short note on the state,
  the gotchas and the pointers, written by whoever stops work on it so the
  next person or agent reads that first instead of the comments (W-1804).

  Rows are never edited. Each write adds one, the newest is the card's
  handoff and the older ones its history. A row with no `next_step` is a
  clear: the card has no handoff, and the history says it was cleared.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @vias ~w(ui api mcp cli runner)

  schema "card_handoffs" do
    field :via, :string
    field :next_step, :string
    field :body, :string

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :job, Slipdock.Runners.Job

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def vias, do: @vias

  @doc "The shape the UI shows as a placeholder and the skills write."
  def body_template do
    """
    State:     what is done and what is half-done
    Next:      the one next step
    Gotchas:   what bit me / what not to try again
    Open:      questions waiting on someone
    Pointers:  branch, files, commits, pages (W-…)
    """
  end

  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [:next_step, :body, :via, :job_id])
    |> update_change(:next_step, &String.trim/1)
    |> update_change(:body, &blank_to_nil/1)
    |> validate_required([:next_step], message: "can't be blank: say the one next step")
    |> validate_required([:via])
    |> validate_length(:next_step, max: 280)
    |> validate_format(:next_step, ~r/\A[^\r\n]*\z/, message: "must be one line")
    |> validate_length(:body, max: 8000)
    |> validate_inclusion(:via, @vias)
  end

  @doc "A clear: no next step and no body, only who, when and how."
  def clear_changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [:via, :job_id])
    |> validate_required([:via])
    |> validate_inclusion(:via, @vias)
  end

  @doc "Whether this row clears the handoff rather than leaving one."
  def cleared?(%__MODULE__{next_step: next}), do: next in [nil, ""]

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(body) do
    case String.trim(body) do
      "" -> nil
      _ -> String.trim_trailing(body)
    end
  end
end
