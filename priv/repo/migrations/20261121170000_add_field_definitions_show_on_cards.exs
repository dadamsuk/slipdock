defmodule Slipdock.Repo.Migrations.AddFieldDefinitionsShowOnCards do
  use Ecto.Migration

  # Whether a custom field's value shows on the card front (#3609); off for
  # every field there is, as it is for a new one.
  def change do
    alter table(:field_definitions) do
      add :show_on_cards, :boolean, null: false, default: false
    end
  end
end
