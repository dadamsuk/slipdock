defmodule Slipdock.Repo.Migrations.CreateCardViews do
  @moduledoc """
  Card views (#2031): a person's named sets of card elements, and the card
  view they use at each level — global (no board), a board, a list. A level
  states only the elements it changes. One row per person per level, held by
  a unique index that counts a missing board or list as one value.
  """
  use Ecto.Migration

  def change do
    create table(:card_views) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :elements, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:card_views, [:user_id, :name])

    create table(:card_view_levels) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all)
      add :column_id, references(:columns, on_delete: :delete_all)
      add :card_view_id, references(:card_views, on_delete: :nilify_all)
      add :elements, :map, null: false, default: %{}
      add :show_all, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :card_view_levels,
             [:user_id, "coalesce(board_id, 0)", "coalesce(column_id, 0)"],
             name: :card_view_levels_one_per_level
           )

    create index(:card_view_levels, [:board_id])
    create index(:card_view_levels, [:column_id])
    create index(:card_view_levels, [:card_view_id])

    create constraint(:card_view_levels, :list_needs_board,
             check: "column_id IS NULL OR board_id IS NOT NULL"
           )
  end
end
