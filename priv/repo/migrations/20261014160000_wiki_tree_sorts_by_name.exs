defmodule Slipdock.Repo.Migrations.WikiTreeSortsByName do
  use Ecto.Migration

  # The wiki's tree reads a-z by default (#789). Nothing kept tells a board
  # that chose "as arranged" from one that never chose at all: "manual" was
  # the column default, and a folder's position is where it was made as
  # often as where it was dragged. So every board on "manual" moves to
  # "name", and positions are left alone: choosing "As arranged" again
  # brings back any order dragged into place. A folder on "manual" stops
  # having a sort of its own (nil), and follows the board's.
  def up do
    alter table(:boards) do
      modify :wiki_sort, :string, null: false, default: "name"
    end

    alter table(:page_folders) do
      modify :sort, :string, null: true, default: nil
    end

    flush()

    Enum.each(backfill(), &execute/1)
  end

  @doc false
  def backfill do
    [
      "UPDATE boards SET wiki_sort = 'name' WHERE wiki_sort = 'manual'",
      "UPDATE page_folders SET sort = NULL WHERE sort = 'manual'"
    ]
  end

  def down do
    execute "UPDATE page_folders SET sort = 'manual' WHERE sort IS NULL"

    alter table(:page_folders) do
      modify :sort, :string, null: false, default: "manual"
    end

    alter table(:boards) do
      modify :wiki_sort, :string, null: false, default: "manual"
    end
  end
end
