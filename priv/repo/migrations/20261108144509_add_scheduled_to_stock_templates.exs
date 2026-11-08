defmodule Slipdock.Repo.Migrations.AddScheduledToStockTemplates do
  use Ecto.Migration

  # A Scheduled list (#2100) is where recurring agent work lands, worked by
  # feed rules and never the ready list. The stock templates that carry a
  # To Do (Slipdock and Simple) get one, after To Do. Templates somebody
  # owns are theirs and left alone, and so is a stock one that already has
  # a list called Scheduled. A sub-board made from them leaves it out
  # (`Slipdock.Boards.create_board/2`).
  @templates ["Slipdock", "Simple"]
  @list %{"name" => "Scheduled", "color" => "violet", "category" => "scheduled"}

  def up do
    for {id, columns} <- stock() do
      names = Enum.map(columns, &String.downcase(to_string(&1["name"])))

      with false <- "scheduled" in names,
           index when is_integer(index) <- Enum.find_index(names, &(&1 == "to do")) do
        update(id, List.insert_at(columns, index + 1, @list))
      end
    end
  end

  def down do
    for {id, columns} <- stock() do
      update(id, Enum.reject(columns, &(&1["category"] == "scheduled")))
    end
  end

  defp stock do
    %{rows: rows} =
      repo().query!(
        "SELECT id, columns FROM board_templates WHERE system AND name = ANY($1)",
        [@templates]
      )

    for [id, columns] <- rows, do: {id, columns}
  end

  defp update(id, columns),
    do: repo().query!("UPDATE board_templates SET columns = $1 WHERE id = $2", [columns, id])
end
