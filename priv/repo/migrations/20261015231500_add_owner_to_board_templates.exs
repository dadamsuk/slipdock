defmodule Slipdock.Repo.Migrations.AddOwnerToBoardTemplates do
  use Ecto.Migration

  # Templates were one global catalogue anybody could rewrite (#856). Now a
  # template is either built in (`system`: nobody's, read-only to everyone,
  # admins included) or somebody's own, seen and changed by them alone.
  #
  # A template goes with its owner: with `system` marking the built-ins, one
  # whose owner had gone would be invisible to everybody and editable by
  # nobody, so it is deleted rather than orphaned. Boards made from it keep
  # their lists (`boards.template_id` is nilified).

  @built_in [
    "Simple",
    "Slipdock",
    "Bug triage",
    "Checklist",
    "Research",
    "Roadmap",
    "Task breakdown",
    "Sprint planning"
  ]

  def up do
    alter table(:board_templates) do
      add :owner_id, references(:users, on_delete: :delete_all)
      add :system, :boolean, null: false, default: false
    end

    create index(:board_templates, [:owner_id])

    flush()

    repo().query!("UPDATE board_templates SET system = true WHERE name = ANY($1)", [@built_in])

    # Anything else was made by somebody: the owner of a board made from it
    # (a board that saved its lists as a template points at it), else the
    # server's first admin, else its first user. A server with no users has
    # no such templates to place.
    repo().query!("""
    UPDATE board_templates t
    SET owner_id = COALESCE(
      (SELECT b.owner_id FROM boards b
       WHERE b.template_id = t.id AND b.owner_id IS NOT NULL
       ORDER BY b.id LIMIT 1),
      (SELECT u.id FROM users u ORDER BY u.admin DESC, u.id LIMIT 1)
    )
    WHERE NOT t.system
    """)

    # Names are unique among one person's templates, and among the built-ins;
    # `Slipdock.Boards` keeps a person's names clear of the built-ins' too.
    drop unique_index(:board_templates, [:name])

    create unique_index(:board_templates, [:owner_id, :name],
             where: "owner_id IS NOT NULL",
             name: :board_templates_owner_id_name_index
           )

    create unique_index(:board_templates, [:name],
             where: "system",
             name: :board_templates_system_name_index
           )
  end

  def down do
    drop index(:board_templates, [:name], name: :board_templates_system_name_index)
    drop index(:board_templates, [:owner_id, :name], name: :board_templates_owner_id_name_index)
    create unique_index(:board_templates, [:name])
    drop index(:board_templates, [:owner_id])

    alter table(:board_templates) do
      remove :system
      remove :owner_id
    end
  end
end
