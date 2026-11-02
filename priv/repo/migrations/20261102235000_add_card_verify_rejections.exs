defmodule Slipdock.Repo.Migrations.AddCardVerifyRejections do
  use Ecto.Migration

  # Verified work 3 (#1624): how many times a card's submitted work has been
  # rejected.
  def change do
    alter table(:cards) do
      add :verify_rejections, :integer, default: 0, null: false
    end
  end
end
