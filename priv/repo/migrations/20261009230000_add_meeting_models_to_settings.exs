defmodule Slipdock.Repo.Migrations.AddMeetingModelsToSettings do
  use Ecto.Migration

  def change do
    # Which models read a meeting: the first reading (nil: the person's own
    # model) and the second — the same model again, another one, or none.
    alter table(:settings) do
      add :meetings_reading_model, :string
      add :meetings_second_reading, :string, default: "same", null: false
      add :meetings_second_model, :string
    end

    # The two readings as they came back, before verification: kept so a
    # restart does not read again, and so the drops can be shown.
    alter table(:captures) do
      add :readings, :map
    end
  end
end
