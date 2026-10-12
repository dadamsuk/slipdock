defmodule Slipdock.Repo.Migrations.CreateWikiChanges do
  use Ecto.Migration

  # Every change to a board's wiki, in order: what sync polls ("changes since
  # cursor", W-103 R2.8). The id is the cursor. Rows are facts about what
  # happened, so they carry no foreign key to the subject: a deleted page's
  # row is how a client learns it is gone.
  def change do
    create table(:wiki_changes) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :subject, :string, null: false
      add :subject_id, :bigint, null: false
      add :action, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:wiki_changes, [:board_id, :id])
  end
end
