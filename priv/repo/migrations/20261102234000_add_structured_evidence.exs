defmodule Slipdock.Repo.Migrations.AddStructuredEvidence do
  use Ecto.Migration

  # Verified work 2 (#1623): evidence in parts the server can check the
  # shape of: the branch, the test files added or changed, and the suite's
  # result with its counts.
  def change do
    alter table(:cards) do
      add :evidence_branch, :string
      add :evidence_tests, {:array, :string}
      add :evidence_suite, :map
    end
  end
end
