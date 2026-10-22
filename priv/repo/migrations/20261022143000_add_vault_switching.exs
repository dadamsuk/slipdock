defmodule Slipdock.Repo.Migrations.AddVaultSwitching do
  use Ecto.Migration

  # Vaults are reached the way boards are (#1204): a key in the board
  # switcher (b, then it), and a Ctrl+Shift digit. The key shares the boards'
  # namespace, so no key ever means two things; a hotkey row points at a
  # board or at a vault, never both.
  def change do
    alter table(:vaults) do
      add :shortcut, :string
    end

    create unique_index(:vaults, [:shortcut])

    alter table(:board_hotkeys) do
      modify :board_id, :bigint, null: true, from: {:bigint, null: false}
      add :vault_id, references(:vaults, on_delete: :delete_all)
    end

    create unique_index(:board_hotkeys, [:user_id, :vault_id])
    create index(:board_hotkeys, [:vault_id])

    create constraint(:board_hotkeys, :board_hotkeys_one_target,
             check: "(board_id IS NULL) <> (vault_id IS NULL)"
           )
  end
end
