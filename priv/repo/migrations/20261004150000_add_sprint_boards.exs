defmodule Slipdock.Repo.Migrations.AddSprintBoards do
  use Ecto.Migration

  # A board can be a particular kind of board — so far only "sprints", where
  # every card is a sprint and its subcards are the sprint's work. A template
  # carries the kind it gives the boards made from it, and "Sprint planning"
  # is the stock template that does.
  def up do
    alter table(:boards) do
      add :kind, :string
    end

    alter table(:board_templates) do
      add :kind, :string
    end

    flush()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    columns = [
      %{name: "Planned", color: "sky", category: "todo"},
      %{name: "Active", color: "amber", category: "doing"},
      %{name: "Closed", color: "emerald", category: "done"}
    ]

    repo().query!(
      """
      INSERT INTO board_templates (name, description, columns, pages, kind, inserted_at, updated_at)
      SELECT $1, $2, $3, $4, $5, $6, $7
      WHERE NOT EXISTS (SELECT 1 FROM board_templates WHERE name = $8)
      """,
      [
        "Sprint planning",
        "Every card is a sprint; its subcards are the sprint's work. New sprint and Add cards… do the setting up.",
        columns,
        [],
        "sprints",
        now,
        now,
        "Sprint planning"
      ]
    )
  end

  def down do
    execute("DELETE FROM board_templates WHERE name = 'Sprint planning'")

    alter table(:board_templates) do
      remove :kind
    end

    alter table(:boards) do
      remove :kind
    end
  end
end
