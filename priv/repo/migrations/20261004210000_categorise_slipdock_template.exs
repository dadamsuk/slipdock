defmodule Slipdock.Repo.Migrations.CategoriseSlipdockTemplate do
  use Ecto.Migration

  # The stock "Slipdock" template gave only Done a category, so a board made
  # from it left agents guessing what Backlog, To Do and In Progress meant.
  # Give them todo, todo, doing — but only while the template still has its
  # stock lists: one somebody has edited is theirs, and left alone.
  @names ["Backlog", "To Do", "In Progress", "Done"]
  @categories ["todo", "todo", "doing", "done"]

  def up, do: recategorise(fn _, category -> category end)

  def down, do: recategorise(fn name, _ -> if name == "Done", do: "done" end)

  defp recategorise(category_for) do
    %{rows: rows} =
      repo().query!("SELECT id, columns FROM board_templates WHERE name = 'Slipdock'")

    for [id, columns] <- rows, Enum.map(columns, & &1["name"]) == @names do
      columns =
        columns
        |> Enum.zip(@categories)
        |> Enum.map(fn {col, category} ->
          Map.put(col, "category", category_for.(col["name"], category))
        end)

      repo().query!("UPDATE board_templates SET columns = $1 WHERE id = $2", [columns, id])
    end
  end
end
