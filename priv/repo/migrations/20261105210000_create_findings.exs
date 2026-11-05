defmodule Slipdock.Repo.Migrations.CreateFindings do
  use Ecto.Migration

  def change do
    # What passes learned, and what the system saw go wrong (see
    # `Slipdock.Findings`), on the root board of the tree.
    create table(:findings) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :nilify_all)
      add :comment_id, references(:comments, on_delete: :nilify_all)
      add :job_id, references(:runner_jobs, on_delete: :nilify_all)
      add :user_id, references(:users, on_delete: :nilify_all)
      add :merged_into_id, references(:findings, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :source, :string, null: false
      add :status, :string, null: false, default: "open"
      add :text, :text, null: false
      add :cause, :string
      add :by, :string
      add :note, :text
      add :count, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:findings, [:board_id, :status])
    create index(:findings, [:card_id])
    create index(:findings, [:comment_id])
  end
end
