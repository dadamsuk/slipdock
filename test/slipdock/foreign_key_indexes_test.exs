defmodule Slipdock.ForeignKeyIndexesTest do
  @moduledoc """
  Foreign keys and their indexes (#3500). Postgres doesn't index the
  referencing side of a foreign key by itself, so without an index leading
  with the column every delete of a parent row scans the child table to
  cascade or nilify, and every lookup by the key does too.

  The check (#3501, a repo check `mix pre_push` runs): every foreign key in
  the migrated schema has a valid index leading with its column, or is on
  `@unindexed` below with the reason it can do without. A new migration that
  adds a key either indexes it or adds it there, with its reason.
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

  # The keys left unindexed on purpose, each with its reason. Each is on a
  # table that stays small: a row per install, per runner, per machine, per
  # tool or per person's setting, so a delete of the parent scans a few rows.
  # A key on a table that grows with use (one row per card, job, comment,
  # email, run or report) is indexed instead.
  @unindexed %{
    {:settings, :ai_system_user_id} => "one settings row per install",
    {:runners, :api_token_id} => "a row per runner",
    {:runners, :created_by_id} => "a row per runner",
    {:runners, :drift_alert_id} => "a row per runner",
    {:vault_mirrors, :token_id} => "a row per person's sync token",
    {:tools, :listed_version_id} => "a row per tool",
    {:tool_versions, :approved_by_id} => "a row per tool version, audit column",
    {:tool_versions, :published_by_id} => "a row per tool version, audit column",
    {:tool_installs, :tool_id} => "a row per board's installed tool",
    {:card_recurrences, :column_id} => "a row per recurring card",
    {:card_recurrences, :created_by_id} => "a row per recurring card, audit column",
    {:runner_pauses, :paused_by_id} => "a row per runner pause, audit column",
    {:runner_pauses, :resumed_by_id} => "a row per runner pause, audit column",
    {:skill_sources, :owner_id} => "a row per skill source a person adds",
    {:skill_enablements, :enabled_by_id} => "a row per enabled skill, audit column",
    {:overseer_settings, :card_id} => "a row per root board",
    {:overseer_settings, :last_job_id} => "a row per root board",
    {:overseer_conditions, :alert_id} => "a row per open condition on a root board",
    {:machine_enrolments, :user_id} => "a row per machine enrolment",
    {:machine_enrolment_keys, :machine_id} => "a row per machine enrolment key"
  }

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

  # Each foreign key `keys` has without an index and not on `allowed`, and
  # each key on `allowed` that is now indexed or gone: both are failures.
  defp unindexed(keys, allowed) do
    missing =
      for {key, false} <- keys, not Map.has_key?(allowed, key), do: key

    stale =
      for {key, _reason} <- allowed, keys[key] != false, do: key

    {Enum.sort(missing), Enum.sort(stale)}
  end

  defp describe_keys(keys), do: Enum.map_join(keys, ", ", fn {t, c} -> "#{t}.#{c}" end)

  describe "every foreign key (#3501)" do
    test "has an index leading with its column, or is on the allowlist with its reason" do
      {missing, stale} = unindexed(foreign_keys(), @unindexed)

      assert missing == [],
             "these foreign keys have no index leading with their column: " <>
               describe_keys(missing) <>
               ". Index each in its migration (`create index(:table, [:column])`, " <>
               "`concurrently: true` on a table that may be large), or, on a table " <>
               "that stays small, add it to @unindexed in #{Path.relative_to_cwd(__ENV__.file)} with why"

      assert stale == [],
             "these keys on @unindexed are indexed now, or gone: take them off it: " <>
               describe_keys(stale)
    end

    test "each allowlisted key says why" do
      for {key, reason} <- @unindexed do
        assert is_binary(reason) and String.trim(reason) != "", "#{inspect(key)} has no reason"
      end
    end

    test "a new foreign key with no index fails it, and indexing it passes" do
      # DDL inside the test's sandbox transaction, rolled back with it. The
      # probe references a parent of its own: a key to a shared table such as
      # `cards` would lock it against every async test inserting there.
      Repo.query!("CREATE TABLE fk_check_parent (id bigserial PRIMARY KEY)")

      Repo.query!(
        "CREATE TABLE fk_check_probe (id bigserial PRIMARY KEY, " <>
          "parent_id bigint REFERENCES fk_check_parent(id))"
      )

      {missing, []} = unindexed(foreign_keys(), @unindexed)
      assert missing == [fk_check_probe: :parent_id]

      Repo.query!("CREATE INDEX ON fk_check_probe (id, parent_id)")

      assert {[fk_check_probe: :parent_id], []} = unindexed(foreign_keys(), @unindexed),
             "an index with the key second doesn't count"

      Repo.query!("CREATE INDEX ON fk_check_probe (parent_id, id)")
      assert {[], []} = unindexed(foreign_keys(), @unindexed)
    end

    test "an allowlisted key that is indexed now fails it as stale" do
      keys = Map.put(foreign_keys(), {:settings, :ai_system_user_id}, true)

      assert {[], [settings: :ai_system_user_id]} = unindexed(keys, @unindexed)
    end
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
