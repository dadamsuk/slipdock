defmodule Slipdock.Repo.Migrations.AddInboundAck do
  use Ecto.Migration

  # The acknowledgement email (#1249): whether a person wants a link back for
  # each card their mail makes, off unless they turn it on, and when one was
  # sent for a message, so no message is ever answered twice.
  def change do
    alter table(:users) do
      add :inbound_ack, :boolean, null: false, default: false
    end

    alter table(:inbound_emails) do
      add :acked_at, :utc_datetime
    end
  end
end
