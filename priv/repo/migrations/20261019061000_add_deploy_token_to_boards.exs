defmodule Slipdock.Repo.Migrations.AddDeployTokenToBoards do
  use Ecto.Migration

  # A board's deploy token (#1134): the hash of the one secret CI holds,
  # which can record deploys for this board and do nothing else. And the
  # pattern that finds card ids in commit messages (nil is `#NNN`).
  def change do
    alter table(:boards) do
      add :deploy_token_hash, :binary
      add :card_ref_pattern, :string
    end

    create unique_index(:boards, [:deploy_token_hash])
  end
end
