defmodule Slipdock.Repo.Migrations.AddSettingsBlockExternalImages do
  use Ecto.Migration

  # Whether pages and cards may load pictures from other hosts (#3559): off
  # until an admin turns it on, so existing pages keep showing theirs.
  def change do
    alter table(:settings) do
      add :block_external_images, :boolean, null: false, default: false
    end
  end
end
