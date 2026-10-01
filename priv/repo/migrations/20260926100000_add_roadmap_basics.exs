defmodule Slipdock.Repo.Migrations.AddRoadmapBasics do
  use Ecto.Migration

  def up do
    schema()
    flush()
    execute "UPDATE columns SET category = 'done' WHERE lower(name) = 'done'"

    # Templates carry categories too: mark their "Done" lists.
    %{rows: rows} = repo().query!("SELECT id, columns FROM board_templates")

    for [id, json] <- rows do
      columns =
        json
        |> Jason.decode!()
        |> Enum.map(fn col ->
          if String.downcase(col["name"] || "") == "done",
            do: Map.put(col, "category", "done"),
            else: col
        end)

      repo().query!("UPDATE board_templates SET columns = ? WHERE id = ?", [
        Jason.encode!(columns),
        id
      ])
    end
  end

  def down do
    drop table(:status_updates)
    drop table(:milestones)
    drop index(:saved_views, [:public_token])

    alter table(:saved_views) do
      remove :public_token
    end

    alter table(:cards) do
      remove :date_precision
    end

    alter table(:columns) do
      remove :category
      remove :horizon_from
      remove :horizon_to
      remove :horizon_unit
    end
  end

  defp schema do
    alter table(:columns) do
      # todo / doing / done / dropped: what being in this list means for a card.
      add :category, :string
      # A horizon: the date range this list stands for (e.g. "Q1 2027").
      add :horizon_from, :date
      add :horizon_to, :date
      # The precision a card dropped into this list is scheduled at.
      add :horizon_unit, :string
    end

    alter table(:cards) do
      # day / week / month / quarter / half / year: how precisely the card is
      # scheduled. Dates are snapped to the bucket the precision implies.
      add :date_precision, :string, null: false, default: "day"
    end

    create table(:milestones) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :date, :date, null: false
      add :color, :string
      add :card_id, references(:cards, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:milestones, [:board_id, :date])

    create table(:status_updates) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :health, :string, null: false
      add :body, :text
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:status_updates, [:card_id, :inserted_at])

    alter table(:saved_views) do
      add :public_token, :string
    end

    create unique_index(:saved_views, [:public_token])
  end
end
