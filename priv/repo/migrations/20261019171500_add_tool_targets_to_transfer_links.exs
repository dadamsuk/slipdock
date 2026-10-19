defmodule Slipdock.Repo.Migrations.AddToolTargetsToTransferLinks do
  use Ecto.Migration

  # A download link can reach a Tool version's skills archive, one skill's
  # claude.ai zip or one file of it (#1158): the version, and which of them
  # (`archive`, `claude:<skill>` or `file:<path>`).
  def change do
    alter table(:transfer_links) do
      add :tool_version_id, references(:tool_versions, on_delete: :delete_all)
      add :tool_target, :string
    end

    create index(:transfer_links, [:tool_version_id])
  end
end
