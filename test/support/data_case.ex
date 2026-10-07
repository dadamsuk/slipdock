defmodule Slipdock.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Slipdock.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Slipdock.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Slipdock.DataCase
    end
  end

  setup tags do
    Slipdock.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Slipdock.Repo, shared: not tags[:async])

    # `Slipdock.Search.Indexer` holds one queue for the whole node, and a
    # test's rows disappear when its transaction rolls back. Starting each
    # test with an empty queue is what stops one test's leftovers from being
    # counted — or flushed — by the next.
    Slipdock.Search.Indexer.reset()

    # `Slipdock.Settings` is one row. Every async test gets its own, so a test
    # that saves settings does not wait on — or deadlock with — another test's
    # uncommitted save. Sync tests keep row 1, because they may rely on a
    # process started at boot, which does not see the override.
    Slipdock.Fixtures.mark_async(tags[:async])

    if tags[:async] do
      Slipdock.TestConfig.put(:settings_row_id, System.unique_integer([:positive]) + 1)
    end

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
