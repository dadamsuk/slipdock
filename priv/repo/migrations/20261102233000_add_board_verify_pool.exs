defmodule Slipdock.Repo.Migrations.AddBoardVerifyPool do
  use Ecto.Migration

  # Verified work 4 (#1634): the runner pool a board sends its pending cards
  # to, as `verify` jobs, for a second agent to check. nil sends none.
  def change do
    alter table(:boards) do
      add :verify_pool, :string
    end
  end
end
