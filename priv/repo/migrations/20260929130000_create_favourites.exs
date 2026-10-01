defmodule Slipdock.Repo.Migrations.CreateFavourites do
  use Ecto.Migration

  @moduledoc """
  Favourites: the things one person wants two taps away — a saved view, a
  list on a board, or a single card.

  They belong to the person who marked them, not to the board, so sharing a
  board never spreads someone else's shortcuts. The shape follows
  `access_grants`: one row, one subject, exactly one resource.

  Saved views already had a `favourite` flag of their own, which was the
  board's, not anyone's. Its rows move across to the people who could have
  set them — the board's owner, and anyone granted access to that board
  directly — and the column goes.
  """

  def up do
    create table(:favourites) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all)
      add :column_id, references(:columns, on_delete: :delete_all)
      add :card_id, references(:cards, on_delete: :delete_all)
      add :saved_view_id, references(:saved_views, on_delete: :delete_all)
      timestamps(type: :utc_datetime)
    end

    create index(:favourites, [:user_id])
    create unique_index(:favourites, [:user_id, :board_id])
    create unique_index(:favourites, [:user_id, :column_id])
    create unique_index(:favourites, [:user_id, :card_id])
    create unique_index(:favourites, [:user_id, :saved_view_id])

    execute """
    INSERT INTO favourites (user_id, saved_view_id, inserted_at, updated_at)
    SELECT DISTINCT u.id, v.id, v.updated_at, v.updated_at
    FROM saved_views v
    JOIN boards b ON b.id = v.board_id
    JOIN users u ON u.id = b.owner_id
                 OR u.id IN (SELECT g.user_id FROM access_grants g WHERE g.board_id = b.id)
    WHERE v.favourite = 1
    """

    alter table(:saved_views) do
      remove :favourite
    end
  end

  def down do
    alter table(:saved_views) do
      add :favourite, :boolean, null: false, default: false
    end

    execute """
    UPDATE saved_views SET favourite = 1
    WHERE id IN (SELECT saved_view_id FROM favourites WHERE saved_view_id IS NOT NULL)
    """

    drop table(:favourites)
  end
end
