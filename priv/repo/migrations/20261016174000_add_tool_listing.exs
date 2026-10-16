defmodule Slipdock.Repo.Migrations.AddToolListing do
  use Ecto.Migration

  # Listing a Tool for everyone on the server (#964) takes an admin's
  # approval of one specific version. The files of a version never change;
  # these columns record what has been asked and decided about it.
  def change do
    alter table(:tool_versions) do
      add :listing_requested_at, :utc_datetime
      add :approved_at, :utc_datetime
      add :approved_by_id, references(:users, on_delete: :nilify_all)
      add :declined_at, :utc_datetime
      add :declined_reason, :string
    end

    alter table(:tools) do
      add :listed_version_id, references(:tool_versions, on_delete: :nilify_all)
    end

    create index(:tool_versions, [:listing_requested_at])
  end
end
