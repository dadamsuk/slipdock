defmodule Slipdock.Repo.Migrations.CreateTemplatesAndSubBoards do
  use Ecto.Migration

  def up do
    create table(:board_templates) do
      add :name, :string, null: false
      add :description, :text
      add :columns, :map, null: false, default: "[]"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_templates, [:name])

    alter table(:boards) do
      # A board owned by a card is that card's sub-board.
      add :parent_card_id, references(:cards, on_delete: :delete_all)
      # The top-level board of the tree (nil for a root board). Tags live on the root.
      add :root_id, references(:boards, on_delete: :delete_all)
      add :template_id, references(:board_templates, on_delete: :nilify_all)
    end

    create unique_index(:boards, [:parent_card_id])
    create index(:boards, [:root_id])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    defaults = [
      {"Slipdock", "The classic four-list flow.",
       [
         %{name: "Backlog"},
         %{name: "To Do"},
         %{name: "In Progress", wip_limit: 3, color: "amber"},
         %{name: "Done", color: "emerald"}
       ]},
      {"Simple", "Three lists, no ceremony.",
       [%{name: "To Do"}, %{name: "Doing", color: "sky"}, %{name: "Done", color: "emerald"}]},
      {"Checklist", "Open or done, nothing in between.",
       [%{name: "Open"}, %{name: "Done", color: "emerald"}]},
      {"Bug triage", "From report to verified fix.",
       [
         %{name: "New", color: "rose"},
         %{name: "Confirmed", color: "orange"},
         %{name: "Fixing", wip_limit: 2, color: "amber"},
         %{name: "Verify", color: "sky"},
         %{name: "Closed", color: "emerald"}
       ]},
      {"Research", "Questions, in progress, findings.",
       [
         %{name: "Questions"},
         %{name: "Investigating", color: "violet"},
         %{name: "Findings", color: "teal"}
       ]}
    ]

    rows =
      for {name, description, columns} <- defaults do
        %{
          name: name,
          description: description,
          columns: Jason.encode!(columns),
          inserted_at: now,
          updated_at: now
        }
      end

    flush()
    repo().insert_all("board_templates", rows)
  end

  def down do
    alter table(:boards) do
      remove :parent_card_id
      remove :root_id
      remove :template_id
    end

    drop table(:board_templates)
  end
end
