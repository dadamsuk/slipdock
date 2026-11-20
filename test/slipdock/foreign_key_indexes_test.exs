defmodule Slipdock.ForeignKeyIndexesTest do
  @moduledoc """
  Foreign keys and their indexes (#3500). Postgres doesn't index the
  referencing side of a foreign key by itself, so without an index leading
  with the column every delete of a parent row scans the child table to
  cascade or nilify, and every lookup by the key does too.
  """
  use Slipdock.DataCase, async: true

  alias Slipdock.Repo

  [{migration, _}] =
    Code.require_file("priv/repo/migrations/20261120010951_index_growing_foreign_keys.exs")

  @migration migration

  # The keys #3500 indexed, written out rather than read off the migration,
  # so dropping one there fails here.
  @growing [
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

  # Every single-column foreign key in the migrated schema, with whether a
  # valid index leads with its column.
  defp foreign_keys do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.conrelid::regclass::text, a.attname,
             EXISTS (SELECT 1 FROM pg_index i
                     WHERE i.indrelid = c.conrelid
                       AND i.indkey[0] = c.conkey[1]
                       AND i.indisvalid)
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1
      """)

    Map.new(rows, fn [table, column, indexed?] ->
      {{String.to_atom(table), String.to_atom(column)}, indexed?}
    end)
  end

  describe "the growing tables' foreign keys (#3500)" do
    test "each has an index leading with its column" do
      keys = foreign_keys()

      for {table, column} = key <- @growing do
        assert Map.has_key?(keys, key), "#{table}.#{column} is not a foreign key"
        assert keys[key], "#{table}.#{column} has no index leading with it"
      end
    end

    test "a key left unindexed reads as unindexed" do
      # A small per-install table's key, which no index leads with: without
      # it, a query that took any index as covering would pass every key.
      assert foreign_keys()[{:settings, :ai_system_user_id}] == false
    end

    test "the review's named keys were indexed already" do
      keys = foreign_keys()

      for key <- [
            activities: :card_id,
            card_tags: :tag_id,
            page_tags: :tag_id,
            group_members: :user_id,
            runner_jobs: :runner_id,
            favourites: :board_id,
            favourites: :card_id,
            transfer_links: :card_id,
            transfer_links: :user_token_id
          ] do
        assert keys[key], "#{inspect(key)} has no index leading with it"
      end
    end

    test "the migration builds exactly those" do
      assert Enum.sort(@migration.indexes()) == Enum.sort(@growing)
    end

    test "the migration builds them concurrently, outside a transaction, under the lock" do
      opts = @migration.__migration__()

      assert opts[:disable_ddl_transaction]
      refute opts[:disable_migration_lock]
      # The table lock holds a transaction open, which CONCURRENTLY can't run in.
      assert Slipdock.Repo.config()[:migration_lock] == :pg_advisory_lock

      for key <- @growing do
        assert @migration.index_for(key).concurrently, "#{inspect(key)} isn't built concurrently"
      end
    end
  end
end
