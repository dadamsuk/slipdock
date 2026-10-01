defmodule Slipdock.Repo.Migrations.AddQuickAddSettingsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Where the header's quick add drops a card when the line doesn't say.
      add :quick_add_board_id, references(:boards, on_delete: :nilify_all)
      add :quick_add_column_id, references(:columns, on_delete: :nilify_all)
      # Whether the line is read by the model as well as the plain parser.
      add :quick_add_ai, :boolean, default: true, null: false
    end
  end
end
