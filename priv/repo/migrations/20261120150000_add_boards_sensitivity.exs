defmodule Slipdock.Repo.Migrations.AddBoardsSensitivity do
  use Ecto.Migration

  # How carefully agents proceed on a board's tree (#3552,
  # `Slipdock.Sensitivity`): low, medium (as before) or high. Read from the
  # tree's root.
  def change do
    alter table(:boards) do
      add :sensitivity, :string, null: false, default: "medium"
    end
  end
end
