defmodule Slipdock.ForeignKeyIndexesRerunTest do
  @moduledoc """
  #3500's migration builds its indexes concurrently, outside a transaction,
  so a run that stops part way keeps the indexes it built and the next run
  starts again from the top. It uses `create_if_not_exists` so that run
  skips them rather than failing on the first one. This runs its `change`
  again on the migrated schema, where every index exists, and expects no
  error.
  """
  # Sync: it runs the migration on the test database outside the sandbox
  # (CREATE INDEX CONCURRENTLY can't run in the sandbox's transaction), so
  # it takes ShareUpdateExclusive locks on the tables whose keys it indexes.
  use Slipdock.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Slipdock.Repo

  # Required, not matched on: the other file testing it may have loaded it
  # already, and then this returns nil.
  Code.require_file("priv/repo/migrations/20261120010951_index_growing_foreign_keys.exs")

  @migration Slipdock.Repo.Migrations.IndexGrowingForeignKeys
  @version 20_261_120_010_951

  test "running it again over the indexes it built changes nothing and doesn't fail" do
    count = fn ->
      Repo.query!("SELECT count(*) FROM pg_indexes WHERE schemaname = 'public'").rows
    end

    before = count.()

    Sandbox.unboxed_run(Repo, fn ->
      Ecto.Migration.Runner.run(Repo, Repo.config(), @version, @migration, :forward, :change, :up,
        log: false
      )
    end)

    assert count.() == before
  end
end
