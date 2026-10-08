defmodule Slipdock.Repo.Migrations.CreateRunnersAndJobs do
  use Ecto.Migration

  # Runners dial out to the server and take jobs from a queue (see
  # `Slipdock.Runners`). A runner belongs to one board tree and one pool; its
  # token is stored only as a hash, like an API token. A job is one card sent
  # to a pool by one rule, and lives on after the runner that ran it is gone.
  def change do
    create table(:runners) do
      add :name, :string, null: false
      add :pool, :string, null: false
      add :token_hash, :binary, null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      # The setup wizard's answers, so the config can be generated again.
      # Never the token.
      add :settings, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime
      add :current_job_id, :bigint
      timestamps(type: :utc_datetime)
    end

    create unique_index(:runners, [:token_hash])
    create index(:runners, [:board_id])

    create table(:runner_jobs) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      # The top of the card's tree: what a runner's scope is checked against.
      add :root_board_id, references(:boards, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :rule_id, references(:automation_rules, on_delete: :nilify_all)
      add :runner_id, references(:runners, on_delete: :nilify_all)
      add :runner_name, :string
      add :pool, :string, null: false
      add :kind, :string, null: false
      add :prompt, :text, null: false
      add :status, :string, null: false, default: "queued"
      add :attempts, :integer, null: false, default: 0
      add :lease_expires_at, :utc_datetime
      add :cancel_requested_at, :utc_datetime
      add :exit_code, :integer
      add :log_tail, :text
      add :output, :text
      add :error, :string
      add :claimed_at, :utc_datetime
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:runner_jobs, [:root_board_id, :pool, :status])
    create index(:runner_jobs, [:card_id])
    create index(:runner_jobs, [:status, :lease_expires_at])

    # At most one open job per card per rule, held by the database so two
    # events arriving together can't both queue one.
    create unique_index(:runner_jobs, [:card_id, :rule_id],
             where: "status IN ('queued', 'claimed', 'running') AND rule_id IS NOT NULL",
             name: :runner_jobs_one_open_per_card_rule
           )
  end
end
