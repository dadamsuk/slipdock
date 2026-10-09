defmodule Slipdock.Repo.Migrations.AddResolveMode do
  use Ecto.Migration

  def change do
    # When a finding was written to the board. A capture can be committed
    # in parts (an item waiting for its speaker's answer follows later), and
    # each finding is still written once only.
    alter table(:capture_findings) do
      add :written_at, :utc_datetime
    end

    # The audio-capable model unclear passages are re-listened to with
    # (nil: re-listening is off).
    alter table(:settings) do
      add :meetings_relisten_model, :string
    end
  end
end
