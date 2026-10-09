defmodule Slipdock.Meetings.Question do
  @moduledoc """
  Something a person has to settle (G3), and — on the same row — how they
  settled it (G4): `answer`, `answered_by`, `answered_at`, `via` (`web`,
  `api`, `agent`) and `context` (what they did first: replayed 07:38–07:44,
  asked the speaker).

  Kinds: `which_reading` (two readings disagree), `who_is_meant` (a name
  nobody here has), `existing_or_new` (a weak link to a card), `who_said_it`
  (a speaker something depends on), `unclear` (words the audio leaves open).

  `status` is `open`, `answered`, or `waiting` (put to the speaker, who has
  not answered yet). A blocking open question keeps the capture from being
  committed.
  """
  use Ecto.Schema

  @kinds ~w(which_reading who_is_meant existing_or_new who_said_it unclear)

  schema "capture_questions" do
    belongs_to :capture, Slipdock.Meetings.Capture
    belongs_to :finding, Slipdock.Meetings.Finding
    field :kind, :string
    field :prompt, :string
    field :options, {:array, :map}, default: []
    field :blocking, :boolean, default: true
    field :status, :string, default: "open"
    field :answer, :map
    belongs_to :answered_by, Slipdock.Accounts.User
    field :answered_at, :utc_datetime
    field :via, :string
    field :context, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
end
