defmodule Slipdock.Repo.Migrations.AddAgentAssigneeIdsToCards do
  use Ecto.Migration

  # Rework (#1659): the people an agent put on a card, so a rejection can take
  # off the builder's own assignment and leave a person's.
  def change do
    alter table(:cards) do
      add :agent_assignee_ids, {:array, :bigint}, default: [], null: false
    end
  end
end
