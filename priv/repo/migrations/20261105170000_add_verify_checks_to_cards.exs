defmodule Slipdock.Repo.Migrations.AddVerifyChecksToCards do
  use Ecto.Migration

  # The last verification's verdict in parts (#1778): the ask, each bar item,
  # the suite, each rule and the Handbook line. Set only by
  # `Slipdock.Verified.decide/5`; a later decision replaces it.
  def change do
    alter table(:cards) do
      add :verify_checks, :map
    end
  end
end
