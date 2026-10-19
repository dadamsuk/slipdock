defmodule Slipdock.Repo.Migrations.CreateRunnerPauses do
  use Ecto.Migration

  # The brake (#1116, KTD10): a board tree, or one runner pool on it, held
  # with a reason. Kept on the root board, since a pool is only a string
  # shared by the whole tree. `pool` nil is the whole tree. An open pause is
  # one with no `resumed_at`; there is at most one per tree and pool.
  #
  # And `automation_wip` (KTD11): the board's owner opting in to WIP limits
  # holding automated work.
  def change do
    create table(:runner_pauses) do
      add :root_board_id, references(:boards, on_delete: :delete_all), null: false
      add :pool, :string
      add :reason, :text, null: false
      add :paused_by_id, references(:users, on_delete: :nilify_all)
      add :agent, :string
      add :resumed_at, :utc_datetime
      add :resumed_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:runner_pauses, [:root_board_id])

    create unique_index(:runner_pauses, ["root_board_id", "coalesce(pool, '')"],
             where: "resumed_at IS NULL",
             name: :runner_pauses_one_open
           )

    alter table(:boards) do
      add :automation_wip, :boolean, null: false, default: false
    end
  end
end
