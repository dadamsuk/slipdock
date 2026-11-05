defmodule Slipdock.Repo.Migrations.AddVerifyAudit do
  use Ecto.Migration

  # Spot-checks of accepted work (#1780): a board audits 1 in N cards an
  # agent accepted (0: none). An audit is a verify job marked `audit`, and it
  # may exclude more than one runner: the card's builder and its verifier.
  def change do
    alter table(:boards) do
      add :verify_audit, :integer, null: false, default: 0
    end

    alter table(:runner_jobs) do
      add :audit, :boolean, null: false, default: false
      add :exclude_runner_ids, {:array, :integer}, null: false, default: []
    end
  end
end
