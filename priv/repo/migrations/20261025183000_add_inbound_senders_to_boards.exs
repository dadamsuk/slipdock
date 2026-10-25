defmodule Slipdock.Repo.Migrations.AddInboundSendersToBoards do
  use Ecto.Migration

  # The other addresses a board's card addresses take mail from (#1289),
  # besides the address owner's own: lower-cased, set by the board's owner.
  def change do
    alter table(:boards) do
      add :inbound_senders, {:array, :string}, null: false, default: []
    end
  end
end
