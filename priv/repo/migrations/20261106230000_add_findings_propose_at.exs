defmodule Slipdock.Repo.Migrations.AddFindingsProposeAt do
  @moduledoc """
  Promotion by recurrence (#1942): a board's `findings_propose_at` (3 by
  default, 0 off) is how many times a finding is counted before the server
  drafts a garden proposal for it. The finding remembers the proposal, the
  rule id it proposes, and its count when it was filed, so it never has two
  open and a dismissed one waits for the count to rise by the threshold again.
  """
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :findings_propose_at, :integer, null: false, default: 3
    end

    alter table(:findings) do
      add :proposal_id, references(:garden_suggestions, on_delete: :nilify_all)
      add :proposed_rule, :string
      add :proposed_at_count, :integer
    end

    create index(:findings, [:proposal_id])
  end
end
