defmodule Slipdock.MigrationLockTest do
  @moduledoc """
  Two nodes booting together both run `Ecto.Migrator` (#3498). That is safe
  because Ecto takes its migration lock (Postgres's default, `:table_lock`:
  `LOCK TABLE schema_migrations IN SHARE UPDATE EXCLUSIVE MODE` in a
  transaction) and reads which migrations have run only once it holds it, so
  the second node waits and then finds nothing to do. It stops being safe if
  the lock is turned off: for the whole repo (`migration_lock: false`), or by
  one migration (`@disable_migration_lock true`, which is what
  `CREATE INDEX CONCURRENTLY` asks for). These hold both. A migration that
  needs to run outside a transaction should switch the repo to
  `migration_lock: :pg_advisory_lock` instead, which still locks.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "the repo keeps a migration lock in every environment" do
    for file <- [
          "config/config.exs",
          "config/dev.exs",
          "config/test.exs",
          "config/prod.exs",
          "config/runtime.exs"
        ],
        path = Path.join(@root, file),
        File.exists?(path) do
      text = File.read!(path)

      refute text =~ ~r/migration_lock:\s*(false|nil)/,
             "#{file} turns Ecto's migration lock off: two nodes booting together would both migrate"
    end

    assert Slipdock.Repo.config()[:migration_lock] in [nil, :table_lock, :pg_advisory_lock]
  end

  test "no migration opts out of the migration lock" do
    offenders =
      @root
      |> Path.join("priv/repo/migrations/*.exs")
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ ~r/@disable_migration_lock\s+true/))
      |> Enum.map(&Path.relative_to(&1, @root))

    assert offenders == [],
           "these migrations run without Ecto's migration lock, so two nodes booting " <>
             "together could both run them; use `migration_lock: :pg_advisory_lock` on the " <>
             "repo instead: #{Enum.join(offenders, ", ")}"
  end
end
