defmodule Slipdock.Repo.Migrations.CreateTransferLinks do
  use Ecto.Migration

  # Short-lived, single-use upload and download URLs (#1147): the hash of the
  # secret in the URL, whose token minted it and the one card, page or
  # attachment it reaches. Deleting the token, the user or the target
  # deletes the link with it.
  def change do
    create table(:transfer_links) do
      add :token_hash, :binary, null: false
      add :kind, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :user_token_id, references(:users_tokens, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :attachment_id, references(:attachments, on_delete: :delete_all)
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:transfer_links, [:token_hash])
    create index(:transfer_links, [:expires_at])

    for column <- [:user_id, :user_token_id, :card_id, :page_id, :attachment_id] do
      create index(:transfer_links, [column])
    end
  end
end
