defmodule Slipdock.Repo.Migrations.AddCodeToBoards do
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:boards) do
      add :code, :string
    end

    create unique_index(:boards, [:code])

    flush()

    # Backfill: every existing board gets a code derived from its name.
    boards =
      Slipdock.Repo.all(
        from(b in "boards", select: %{id: b.id, name: b.name}, order_by: [asc: b.id])
      )

    Enum.reduce(boards, MapSet.new(), fn board, taken ->
      code = Slipdock.Boards.Board.code_from_name(board.name, taken)

      Slipdock.Repo.update_all(
        from(b in "boards", where: b.id == ^board.id),
        set: [code: code]
      )

      MapSet.put(taken, code)
    end)
  end

  def down do
    drop unique_index(:boards, [:code])

    alter table(:boards) do
      remove :code
    end
  end
end
