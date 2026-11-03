defmodule Slipdock.Repo.Migrations.AddMergeShaToCards do
  use Ecto.Migration

  # Ship by PR 4 (#1657): the commit a card's pull request was merged as.
  def change do
    alter table(:cards) do
      add :merge_sha, :string
    end
  end
end
