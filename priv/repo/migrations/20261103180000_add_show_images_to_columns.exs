defmodule Slipdock.Repo.Migrations.AddShowImagesToColumns do
  use Ecto.Migration

  # Whether a list's cards show their image on the front: on unless a list's
  # settings turn it off.
  def change do
    alter table(:columns) do
      add :show_images, :boolean, null: false, default: true
    end
  end
end
