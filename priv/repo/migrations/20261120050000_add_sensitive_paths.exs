defmodule Slipdock.Repo.Migrations.AddSensitivePaths do
  use Ecto.Migration

  # The paths whose change a person approves before a card's pull request
  # merges (#3519): nil is the defaults (`Board.sensitive_paths/1`). And the
  # commit a person approved merging, on the card.
  def change do
    alter table(:boards) do
      add :sensitive_paths, {:array, :string}
    end

    alter table(:cards) do
      add :merge_approved_commit, :string
    end
  end
end
