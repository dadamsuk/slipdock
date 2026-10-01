defmodule Slipdock.Repo.Migrations.AddRoadmapTemplate do
  use Ecto.Migration

  # A template for the top of a tree: horizons rather than workflow stages.
  def up do
    %{rows: rows} = repo().query!("SELECT id FROM board_templates WHERE name = 'Roadmap'")

    if rows == [] do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      columns =
        Jason.encode!([
          %{name: "Now", color: "amber"},
          %{name: "Next", color: "sky"},
          %{name: "Later"},
          %{name: "Done", color: "emerald"}
        ])

      repo().insert_all("board_templates", [
        %{
          name: "Roadmap",
          description:
            "Horizons for a roadmap: now, next, later. Give each card subcards for the work beneath.",
          columns: columns,
          inserted_at: now,
          updated_at: now
        }
      ])
    end
  end

  def down do
    repo().query!("DELETE FROM board_templates WHERE name = 'Roadmap'")
  end
end
