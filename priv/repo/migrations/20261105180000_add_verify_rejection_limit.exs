defmodule Slipdock.Repo.Migrations.AddVerifyRejectionLimit do
  use Ecto.Migration

  # Repeated rejections go to a person (#1779): the rejections a card may
  # have before the next opens a wait on the board's owner (0: no limit),
  # and what a wait is for, so its answer can rework or accept the card.
  def change do
    alter table(:boards) do
      add :verify_rejection_limit, :integer, null: false, default: 2
    end

    alter table(:card_waits) do
      add :purpose, :string
    end
  end
end
