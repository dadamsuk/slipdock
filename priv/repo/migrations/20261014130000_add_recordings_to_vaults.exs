defmodule Slipdock.Repo.Migrations.AddRecordingsToVaults do
  use Ecto.Migration

  # A vault's recordings folder on Google Drive (W-1690), and what its paths
  # were found to be: path → Drive file id, mime type and size, so playing a
  # recording a second time does not walk Drive folder by folder again.
  def change do
    alter table(:vaults) do
      add :recordings_folder, :string
    end

    create table(:recording_files) do
      add :vault_id, references(:vaults, on_delete: :delete_all), null: false
      add :path, :text, null: false
      add :drive_id, :string, null: false
      add :mime_type, :string
      add :size, :bigint

      timestamps(type: :utc_datetime)
    end

    create unique_index(:recording_files, [:vault_id, :path])
  end
end
