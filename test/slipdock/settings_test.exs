defmodule Slipdock.SettingsTest do
  @moduledoc """
  The settings row: defaults before anything is saved, seeding from the
  environment exactly once, the setup token, and the allowlist.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Settings

  defp with_config(key, value) do
    previous = Application.fetch_env(:slipdock, key)
    Application.put_env(:slipdock, key, value)

    on_exit(fn ->
      case previous do
        {:ok, previous} -> Application.put_env(:slipdock, key, previous)
        :error -> Application.delete_env(:slipdock, key)
      end
    end)
  end

  describe "get/0 before anything is saved" do
    test "answers with the configured defaults rather than nil" do
      with_config(:settings, signup_mode: :allowlist, free_card_limit: 20)

      settings = Settings.get()
      assert settings.signup_mode == :allowlist
      assert settings.free_card_limit == 20
      assert settings.user_directory == :instance
      assert settings.invites_create_accounts == true
    end

    test "reads the old :signups config so an un-migrated instance behaves as it did" do
      with_config(:settings, [])
      with_config(:signups, open: true)

      assert Settings.signup_mode() == :open
    end

    test "an instance with no setup_completed default is not set up" do
      with_config(:settings, [])
      refute Settings.setup_complete?()
    end
  end

  describe "update/1" do
    test "writes the row the first time and updates it after" do
      assert {:ok, settings} = Settings.update(%{"signup_mode" => :approval})
      assert settings.signup_mode == :approval
      assert Settings.signup_mode() == :approval

      assert {:ok, _} = Settings.update(%{"free_card_limit" => 20})
      # The earlier change is still there: one row, not a new one each time.
      assert Settings.signup_mode() == :approval
      assert Settings.free_card_limit() == 20
      assert Repo.aggregate(Settings.Instance, :count) == 1
    end

    test "a blank SMTP host means not configured, not configured-as-empty" do
      assert {:ok, _} = Settings.update(%{"smtp_host" => "   "})
      refute Settings.smtp_configured?()
    end

    test "a host needs an address to send from" do
      assert {:error, changeset} = Settings.update(%{"smtp_host" => "smtp.example.com"})
      assert %{smtp_from_email: [_ | _]} = errors_on(changeset)
    end

    test "changing how mail is sent drops the last successful test send" do
      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "mail@example.com"
        })

      {:ok, settings} = Settings.mark_smtp_verified()
      assert settings.smtp_verified_at

      {:ok, settings} = Settings.update(%{"smtp_host" => "smtp.elsewhere.com"})
      refute settings.smtp_verified_at
    end

    test "rejects a free card limit of zero, which would mean nobody can do anything" do
      assert {:error, changeset} = Settings.update(%{"free_card_limit" => 0})
      assert %{free_card_limit: [_ | _]} = errors_on(changeset)
    end
  end

  describe "the setup token" do
    setup do
      with_config(:settings, [])
      :ok
    end

    test "is minted once and stays the same across calls" do
      token = Settings.ensure_setup_token()
      assert is_binary(token)
      assert Settings.ensure_setup_token() == token
      assert Settings.valid_setup_token?(token)
    end

    test "refuses a wrong, blank or missing token" do
      Settings.ensure_setup_token()
      refute Settings.valid_setup_token?("nonsense")
      refute Settings.valid_setup_token?("")
      refute Settings.valid_setup_token?(nil)
    end

    test "is gone once setup is complete, and no token works any more" do
      token = Settings.ensure_setup_token()
      {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})

      assert Settings.setup_complete?()
      refute Settings.valid_setup_token?(token)
      refute Settings.ensure_setup_token()
    end
  end

  describe "complete_setup/1" do
    test "needs an admin address — that is the whole point of it" do
      with_config(:settings, [])
      assert {:error, changeset} = Settings.complete_setup(%{})
      assert %{admin_email: [_ | _]} = errors_on(changeset)
      refute Settings.setup_complete?()
    end
  end

  describe "the allowlist" do
    test "matches a whole address" do
      {:ok, _} = Settings.add_allowlist_entry("Friend@Example.com")
      assert Settings.allowlisted?("friend@example.com")
      refute Settings.allowlisted?("stranger@example.com")
    end

    test "a bare domain means anybody there" do
      {:ok, _} = Settings.add_allowlist_entry("example.org")
      assert Settings.allowlisted?("anyone@example.org")
      assert Settings.allowlisted?("ANYONE@Example.ORG")
      refute Settings.allowlisted?("anyone@example.net")
    end

    test "a leading @ is the same entry as without one" do
      {:ok, _} = Settings.add_allowlist_entry("@example.org")
      assert {:ok, _} = Settings.add_allowlist_entry("example.org")
      assert length(Settings.list_allowlist()) == 1
    end

    test "records when an entry last let somebody in" do
      {:ok, entry} = Settings.add_allowlist_entry("example.org")
      refute entry.last_used_at

      assert Settings.allowlisted?("someone@example.org")
      assert Repo.reload(entry).last_used_at
    end

    test "refuses something that is neither an address nor a domain" do
      assert {:error, changeset} = Settings.add_allowlist_entry("not an address")
      assert %{entry: [_ | _]} = errors_on(changeset)
    end
  end

  describe "seed/0" do
    setup do
      with_config(:settings, [])
      with_config(:signups, [])
      :ok
    end

    test "carries the old open-signup config into the row" do
      with_config(:signups, open: true)
      assert :ok = Settings.seed()
      assert Settings.signup_mode() == :open
    end

    test "carries the old allowlist across as rows" do
      with_config(:signups, open: false, allow: ["example.com", "friend@elsewhere.com"])
      assert :ok = Settings.seed()

      assert Settings.signup_mode() == :allowlist
      assert Settings.allowlisted?("anyone@example.com")
      assert Settings.allowlisted?("friend@elsewhere.com")
    end

    test "marks an instance that already has users as set up" do
      user_fixture("owner@example.com")
      assert :ok = Settings.seed()

      assert Settings.setup_complete?()
      assert Settings.get().admin_email == "owner@example.com"
    end

    test "SLIPDOCK_ADMIN_EMAIL skips the wizard outright" do
      with_config(:settings, admin_email: "admin@example.com")
      assert :ok = Settings.seed()

      assert Settings.setup_complete?()
      assert Settings.get().admin_email == "admin@example.com"
    end

    test "leaves an empty instance unclaimed, so the wizard can run" do
      assert :ok = Settings.seed()
      refute Settings.setup_complete?()
    end

    test "never touches a row that already exists" do
      {:ok, _} = Settings.update(%{"signup_mode" => :closed})
      with_config(:signups, open: true)

      assert :ok = Settings.seed()
      # The environment lost, which is the whole contract.
      assert Settings.signup_mode() == :closed
    end
  end
end
