defmodule Slipdock.Repo.Migrations.AddFindingLessons do
  @moduledoc """
  One finding per lesson (#1941): `lesson` is the normalised text repeats are
  matched on, `comment_ids` the comments that said it (so a comment edited or
  deleted takes back only its own count), and `scope` with `runner` keeps a
  finding about one machine's tooling with that runner, out of the board's list.
  """
  use Ecto.Migration

  def up do
    alter table(:findings) do
      add :lesson, :text
      add :comment_ids, {:array, :bigint}, null: false, default: []
      add :scope, :string, null: false, default: "board"
      add :runner_id, references(:runners, on_delete: :nilify_all)
    end

    create index(:findings, [:board_id, :lesson], where: "status = 'open'")
    create index(:findings, [:runner_id])

    flush()

    execute("""
    UPDATE findings SET comment_ids = ARRAY[comment_id]
    WHERE comment_id IS NOT NULL AND source = 'agent'
    """)

    # The key is worked out in Elixir, as new findings' are.
    %{rows: rows} = repo().query!("SELECT id, text FROM findings")

    for [id, text] <- rows do
      repo().query!("UPDATE findings SET lesson = $1 WHERE id = $2", [
        Slipdock.Findings.Lesson.normalise(text),
        id
      ])
    end
  end

  def down do
    alter table(:findings) do
      remove :runner_id
      remove :scope
      remove :comment_ids
      remove :lesson
    end
  end
end
