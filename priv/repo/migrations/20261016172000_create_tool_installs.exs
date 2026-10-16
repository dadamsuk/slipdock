defmodule Slipdock.Repo.Migrations.CreateToolInstalls do
  use Ecto.Migration

  # Who installed which Tool, at which version, onto which board (#961). One
  # per person and Tool, so installing again finds the board rather than
  # making a second; a board that has since been deleted leaves the row with
  # no board, and the next install makes a new one.
  def change do
    create table(:tool_installs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :tool_id, references(:tools, on_delete: :delete_all), null: false
      add :version, :string, null: false
      add :board_id, references(:boards, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tool_installs, [:user_id, :tool_id])
    create index(:tool_installs, [:board_id])
  end
end
