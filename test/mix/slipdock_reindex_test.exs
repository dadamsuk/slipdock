defmodule Mix.Tasks.Slipdock.ReindexTest do
  @moduledoc """
  `mix slipdock.reindex` when there is nothing to embed with: it stops before
  walking anything, and says where an admin fixes it.
  """
  # Sync: Mix.shell is global.
  use Slipdock.DataCase, async: false

  setup do
    key_file = Path.join(System.tmp_dir!(), "ai_keys_#{System.unique_integer([:positive])}.json")
    Slipdock.TestConfig.merge(:ai, key_file: key_file, api_key: nil, system_user: nil)
    on_exit(fn -> File.rm(key_file) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "with no AI for unattended work it refuses, pointing at Configuration" do
    error = assert_raise Mix.Error, fn -> Mix.Tasks.Slipdock.Reindex.run([]) end

    assert error.message =~ "Configuration → AI for search and automations"
    assert error.message =~ "slipdock admin set ai_system_user="
    refute error.message =~ "OPENROUTER_API_KEY is not set"
  end
end
