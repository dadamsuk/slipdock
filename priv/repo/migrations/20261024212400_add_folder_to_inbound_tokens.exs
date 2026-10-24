defmodule Slipdock.Repo.Migrations.AddFolderToInboundTokens do
  use Ecto.Migration

  # A folder's own `page-…` address (#1277): a token with a folder as well as
  # its board, one live per person per folder. The board's live token is now
  # the one without a folder, so its index leaves folder tokens out. A
  # deleted folder takes its tokens with it.
  def change do
    alter table(:inbound_tokens) do
      add :folder_id, references(:page_folders, on_delete: :delete_all)
    end

    drop unique_index(:inbound_tokens, [:user_id, :board_id],
           where: "revoked_at IS NULL AND board_id IS NOT NULL",
           name: :inbound_tokens_live_board_index
         )

    create unique_index(:inbound_tokens, [:user_id, :board_id],
             where: "revoked_at IS NULL AND board_id IS NOT NULL AND folder_id IS NULL",
             name: :inbound_tokens_live_board_index
           )

    create unique_index(:inbound_tokens, [:user_id, :folder_id],
             where: "revoked_at IS NULL AND folder_id IS NOT NULL",
             name: :inbound_tokens_live_folder_index
           )

    create index(:inbound_tokens, [:folder_id])
  end
end
