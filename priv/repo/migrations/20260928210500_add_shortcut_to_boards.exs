defmodule Slipdock.Repo.Migrations.AddShortcutToBoards do
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:boards) do
      add :shortcut, :string
    end

    create unique_index(:boards, [:shortcut])

    flush()

    # Backfill: every top-level board gets a key off its name. Sub-boards keep
    # a null one — the switcher only lists boards you can open from the top.
    boards =
      Slipdock.Repo.all(
        from(b in "boards",
          where: is_nil(b.parent_card_id),
          select: %{id: b.id, name: b.name},
          order_by: [asc: b.id]
        )
      )

    Enum.reduce(boards, MapSet.new(), fn board, taken ->
      shortcut = Slipdock.Boards.Board.shortcut_from_name(board.name, taken)

      Slipdock.Repo.update_all(
        from(b in "boards", where: b.id == ^board.id),
        set: [shortcut: shortcut]
      )

      MapSet.put(taken, shortcut)
    end)
  end

  def down do
    drop unique_index(:boards, [:shortcut])

    alter table(:boards) do
      remove :shortcut
    end
  end
end
