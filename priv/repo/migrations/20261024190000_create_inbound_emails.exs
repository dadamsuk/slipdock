defmodule Slipdock.Repo.Migrations.CreateInboundEmails do
  use Ecto.Migration

  # Every message the inbound endpoint has decided about (#1236, W-1933): what
  # it was, what came of it and why, so a repeat delivery is answered without a
  # second write and "I emailed it and nothing happened" has an answer. The raw
  # message is never kept.
  def change do
    create table(:inbound_emails) do
      add :message_id, :text, null: false
      add :recipient, :text, null: false
      add :sender, :text
      add :subject, :text
      add :kind, :text, null: false
      add :outcome, :text, null: false
      add :reason, :text
      add :size, :integer, null: false, default: 0
      add :user_id, references(:users, on_delete: :delete_all)
      add :card_id, references(:cards, on_delete: :nilify_all)
      add :page_id, references(:pages, on_delete: :nilify_all)
      add :comment_id, references(:comments, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:inbound_emails, [:message_id, :recipient])
    create index(:inbound_emails, [:user_id, :inserted_at])
  end
end
