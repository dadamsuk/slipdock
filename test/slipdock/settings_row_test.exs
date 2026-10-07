defmodule Slipdock.SettingsRowTest do
  @moduledoc """
  Each async test saves settings into a row of its own (see
  `Slipdock.DataCase`), which is what lets the tests about limits and
  registration run alongside the rest. Async on purpose.
  """
  use Slipdock.DataCase, async: true

  alias Slipdock.{Config, Settings}

  test "an async test's settings are a row of its own, not row 1" do
    assert Config.get(:settings_row_id) not in [nil, 1]

    {:ok, saved} = Settings.update(%{"free_card_limit" => 7})

    assert saved.id == Config.get(:settings_row_id)
    assert Settings.get().free_card_limit == 7
  end

  test "what the test starts reads the test's row" do
    {:ok, _} = Settings.update(%{"free_card_limit" => 9})

    assert Task.async(fn -> Settings.get().free_card_limit end) |> Task.await() == 9
  end

  test "another row id does not see this test's save, and reads the defaults" do
    {:ok, _} = Settings.update(%{"free_card_limit" => 11, "user_directory" => "shared_only"})

    elsewhere =
      Task.async(fn ->
        Config.override(:settings_row_id, Config.get(:settings_row_id) + 1_000_000)
        settings = Settings.get()
        Config.clear_overrides(self())
        settings
      end)
      |> Task.await()

    assert elsewhere.free_card_limit == nil
    assert elsewhere.user_directory == :instance
    assert Settings.get().user_directory == :shared_only
  end

  test "complete_setup writes the same row" do
    {:ok, done} = Settings.complete_setup(%{"admin_email" => "row@example.com"})

    assert done.id == Config.get(:settings_row_id)
    assert Settings.setup_complete?()
  end
end
