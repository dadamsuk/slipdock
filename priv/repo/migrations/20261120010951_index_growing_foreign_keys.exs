defmodule Slipdock.Repo.Migrations.IndexGrowingForeignKeys do
  use Ecto.Migration

  # The foreign keys left without an index that leads with their column, on
  # the tables that grow with use (#3500). Postgres doesn't index the
  # referencing side by itself, so deleting a parent row (a runner, a card, a
  # page, a user's token) scanned the whole child table to cascade or nilify,
  # and a lookup by the key (a runner's jobs, a job's findings) did too.
  #
  # Concurrently, so an install with large tables keeps taking writes while
  # each index builds. That can't run inside a transaction, so this one has
  # none; the repo's advisory migration lock (config/config.exs) holds no
  # transaction, so it stays on and two booting nodes still migrate once
  # (#3498). With no transaction, a run that stops part way keeps the
  # indexes it built: `create_if_not_exists` lets the next run skip those.
  # A concurrent build that fails leaves an
  # INVALID index of that name, which the next run would skip too: drop it
  # (`DROP INDEX CONCURRENTLY <name>`) before migrating again.
  #
  # The keys left unindexed on purpose (small per-install tables) are on the
  # allowlist in test/slipdock/foreign_key_indexes_test.exs.
  @disable_ddl_transaction true

  @indexes [
    cards: :snoozed_by_id,
    oauth_codes: :client_id,
    oauth_codes: :token_id,
    oauth_codes: :user_id,
    runner_jobs: :board_id,
    runner_jobs: :last_runner_id,
    runner_jobs: :rule_id,
    runner_jobs: :runner_id,
    runner_jobs: :transcript_page_id,
    wiki_files: :created_by_id,
    card_recurrences: :last_created_card_id,
    garden_runs: :user_id,
    inbound_emails: :card_id,
    inbound_emails: :comment_id,
    inbound_emails: :page_id,
    page_autosaves: :board_id,
    page_autosaves: :page_id,
    health_incidents: :alert_id,
    findings: :job_id,
    findings: :merged_into_id,
    findings: :user_id,
    machine_config_reports: :runner_id,
    release_requests: :job_id
  ]

  def change do
    for key <- @indexes do
      create_if_not_exists index_for(key)
    end
  end

  @doc false
  def index_for({table, column}), do: index(table, [column], concurrently: true)

  @doc false
  def indexes, do: @indexes
end
