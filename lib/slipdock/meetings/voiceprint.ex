defmodule Slipdock.Meetings.Voiceprint do
  @moduledoc """
  One person's voiceprint: an embedding of their voice, never the audio it
  was made from, and the consent it was made under. At most one each. Where
  it came from is `source`: `"recording"` (their own short recording) or
  `"meeting"` (a meeting where their voice was confirmed, `source_capture`).
  """
  use Ecto.Schema

  schema "voiceprints" do
    belongs_to :user, Slipdock.Accounts.User
    field :embedding, {:array, :float}
    field :source, :string
    belongs_to :source_capture, Slipdock.Meetings.Capture
    field :consent_version, :string
    field :consented_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end

defmodule Slipdock.Meetings.VoiceprintConsent do
  @moduledoc """
  Consent to a voiceprint, `"given"` or `"withdrawn"`: who, when, and the
  wording they were shown, word for word. Outlives the voiceprint, so the
  record says it was deleted.
  """
  use Ecto.Schema

  schema "voiceprint_consents" do
    belongs_to :user, Slipdock.Accounts.User
    field :event, :string
    field :wording_version, :string
    field :wording, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
