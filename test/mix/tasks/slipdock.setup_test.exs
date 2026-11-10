defmodule Mix.Tasks.Slipdock.SetupTest do
  @moduledoc """
  `mix slipdock.setup --admin …`: the values it takes for `--mode` and
  `--directory` are saved, any other value stops it with the list of good ones,
  and a server already set up is refused.
  """
  # Sync: Mix.shell is global, and so is the settings row.
  use Slipdock.DataCase, async: false

  alias Mix.Tasks.Slipdock.Setup
  alias Slipdock.Settings

  setup do
    # config/test.exs describes a server already set up; this one is not.
    Slipdock.TestConfig.merge(:settings, setup_completed: false)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  @mail ~w(--smtp-host smtp.example.com --smtp-from slipdock@example.com)

  defp set_up(args), do: Setup.run(["--admin", "admin@example.com" | args])

  describe "--mode" do
    for mode <- ~w(open allowlist approval closed) do
      test "#{mode} is saved" do
        # approval tells somebody a person is waiting, so it needs mail.
        set_up(["--mode", unquote(mode) | @mail])

        assert Settings.setup_complete?()
        assert Settings.signup_mode() == String.to_existing_atom(unquote(mode))
      end
    end

    for bad <- ["anyone", "Open", ""] do
      test "#{inspect(bad)} is refused and nothing is set up" do
        error = assert_raise Mix.Error, fn -> set_up(["--mode", unquote(bad)]) end

        assert error.message == "--mode must be one of: open, allowlist, approval, closed"
        refute Settings.setup_complete?()
      end
    end
  end

  describe "--directory" do
    for directory <- ~w(instance shared_only) do
      test "#{directory} is saved" do
        set_up(["--directory", unquote(directory)])

        assert Settings.setup_complete?()
        assert Settings.user_directory() == String.to_existing_atom(unquote(directory))
      end
    end

    for bad <- ["everyone", "Instance", ""] do
      test "#{inspect(bad)} is refused and nothing is set up" do
        error = assert_raise Mix.Error, fn -> set_up(["--directory", unquote(bad)]) end

        assert error.message == "--directory must be instance or shared_only"
        refute Settings.setup_complete?()
      end
    end
  end

  test "a server already set up is refused, naming its admin" do
    set_up([])
    assert Settings.setup_complete?()

    error =
      assert_raise Mix.Error, fn ->
        Setup.run(["--admin", "other@example.com", "--mode", "open"])
      end

    assert error.message =~ "already been set up; admin@example.com is the admin"
    assert Settings.get().admin_email == "admin@example.com"
  end
end
