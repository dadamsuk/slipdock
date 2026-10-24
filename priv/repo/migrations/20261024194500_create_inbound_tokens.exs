defmodule Slipdock.Repo.Migrations.CreateInboundTokens do
  use Ecto.Migration

  # The tokens in inbound addresses (#1244, W-1933): one per person per board
  # they can write to (`card-…` and `page-…`), and one personal one with no
  # board (`add-…`). Looked up by hash; kept encrypted as well, so the address
  # can be shown again. A rotated or revoked row stays, for the record.
  def change do
    create table(:inbound_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all)
      add :token_hash, :binary, null: false
      add :token_encrypted, :binary, null: false
      add :rotated_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:inbound_tokens, [:token_hash])

    create unique_index(:inbound_tokens, [:user_id, :board_id],
             where: "revoked_at IS NULL AND board_id IS NOT NULL",
             name: :inbound_tokens_live_board_index
           )

    create unique_index(:inbound_tokens, [:user_id],
             where: "revoked_at IS NULL AND board_id IS NULL",
             name: :inbound_tokens_live_personal_index
           )

    create index(:inbound_tokens, [:board_id])
  end
end
