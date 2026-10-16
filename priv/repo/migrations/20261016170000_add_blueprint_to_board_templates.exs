defmodule Slipdock.Repo.Migrations.AddBlueprintToBoardTemplates do
  use Ecto.Migration

  # The rest of a board blueprint (#959): a template can carry wiki folders,
  # tags and automation recipes as well as lists and pages.
  def change do
    alter table(:board_templates) do
      add :folders, {:array, :string}, default: [], null: false
      add :tags, {:array, :map}, default: [], null: false
      add :automations, {:array, :map}, default: [], null: false
    end
  end
end
