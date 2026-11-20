defmodule Slipdock.Repo.Migrations.CreateRunnerPoolGrants do
  use Ecto.Migration

  # Who besides a board's owner takes a runner pool's jobs (#3492): one row
  # per person, root board and pool, made by the board's owner.
  def change do
    create table(:runner_pool_grants) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :pool, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :granted_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:runner_pool_grants, [:board_id, :pool, :user_id])
    create index(:runner_pool_grants, [:user_id])
    create index(:runner_pool_grants, [:granted_by_id])
  end
end
