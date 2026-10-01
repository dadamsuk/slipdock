defmodule Slipdock.Repo.Migrations.ArchiveAndOrderBoards do
  use Ecto.Migration

  @moduledoc """
  Archiving and ordering for whole boards.

  * `boards.archived_at` puts a board away without deleting it: it drops off
    the board index, the switcher, quick add and the boards a card can move
    to, but everything on it stays — the link still opens it and its cards
    still turn up in search.

  * `board_orders` is the order one person lists boards in. It follows
    `favourites`: the row belongs to the person, not to the board, so
    rearranging your own index never moves anyone else's. A board with no row
    has not been placed yet and keeps its place at the end, oldest first —
    which is the order everyone had before this.

  * `users.board_layout` and `users.board_sort` are that person's view of the
    index: cards or a compact table, and which order to list them in.
  """

  def up do
    alter table(:boards) do
      add :archived_at, :utc_datetime
    end

    alter table(:users) do
      add :board_layout, :string, null: false, default: "grid"
      add :board_sort, :string, null: false, default: "manual"
    end

    create table(:board_orders) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_orders, [:user_id, :board_id])
  end

  def down do
    drop table(:board_orders)

    alter table(:users) do
      remove :board_layout
      remove :board_sort
    end

    alter table(:boards) do
      remove :archived_at
    end
  end
end
