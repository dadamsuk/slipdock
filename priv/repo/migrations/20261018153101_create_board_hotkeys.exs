defmodule Slipdock.Repo.Migrations.CreateBoardHotkeys do
  use Ecto.Migration

  # Ctrl+Shift+a digit, from anywhere, to one board (#1101). The digit is the
  # person's own, like a board's place on their index: ten of them to go
  # round, so two people sharing a board never fight over one.
  def change do
    create table(:board_hotkeys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :digit, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_hotkeys, [:user_id, :digit])
    create unique_index(:board_hotkeys, [:user_id, :board_id])
    create index(:board_hotkeys, [:board_id])
  end
end
