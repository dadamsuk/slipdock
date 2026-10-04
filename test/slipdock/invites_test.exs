defmodule Slipdock.InvitesTest do
  @moduledoc """
  Sharing something with an address nobody here uses — the only way an account
  comes into existence without its owner asking for one, and so the only way
  round the registration mode if it is not governed.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Access, Accounts, Settings}

  defp set_up(attrs) do
    {:ok, _} =
      Settings.complete_setup(
        Map.merge(%{"admin_email" => "admin@example.com", "signup_mode" => :closed}, attrs)
      )

    :ok
  end

  defp mail, do: %{"smtp_host" => "smtp.example.com", "smtp_from_email" => "mail@example.com"}

  setup do
    alice = user_fixture("alice@example.com")
    %{alice: alice, board: board_fixture(%{"name" => "Roadmap"}, owner: alice)}
  end

  describe "when this server makes accounts for people you share with" do
    setup do: set_up(Map.merge(mail(), %{"invites_create_accounts" => true}))

    test "sharing a board with a stranger gives them an account", %{alice: alice, board: board} do
      assert {:ok, _} = Access.grant(board, "newcomer@example.com", "read", alice)

      user = Accounts.get_user_by_email("newcomer@example.com")
      assert user
      assert user.invited_by_id == alice.id
      assert user.invited_at
    end

    test "and tells them, naming who did it and what for", %{alice: alice, board: board} do
      {:ok, _} = Access.grant(board, "newcomer@example.com", "read", alice)

      assert_email_sent(fn email ->
        assert email.to == [{"newcomer@example.com", "newcomer@example.com"}]
        assert email.subject =~ "alice@example.com"
        assert email.text_body =~ "Roadmap"
      end)
    end

    test "a group does the same, in its owner's name", %{alice: alice} do
      {:ok, group} = Accounts.create_group(alice, %{"name" => "Design"})
      {:ok, _} = Accounts.add_group_member(group, "newcomer@example.com")

      user = Accounts.get_user_by_email("newcomer@example.com")
      assert user.invited_by_id == alice.id
    end

    test "an address already here is not re-invited", %{alice: alice, board: board} do
      bob = user_fixture("bob@example.com")
      {:ok, _} = Access.grant(board, "bob@example.com", "read", alice)

      assert Repo.reload(bob).invited_at == nil
    end

    test "an invited account may sign in, though the mode is closed" do
      # Deliberate, and the reason is in `signup_allowed?/1`: the question is
      # asked once, when the account is made. An account somebody deliberately
      # created which then cannot be used is a bug report waiting to happen.
      alice = Accounts.get_user_by_email("alice@example.com")
      board = board_fixture(%{"name" => "Other"}, owner: alice)
      {:ok, _} = Access.grant(board, "newcomer@example.com", "read", alice)

      assert Settings.signup_mode() == :closed
      assert Accounts.signup_allowed?("newcomer@example.com")
    end

    test "disabling them does close it", %{alice: alice, board: board} do
      {:ok, _} = Access.grant(board, "newcomer@example.com", "read", alice)
      {:ok, _} = Accounts.promote(user_fixture("admin@example.com"))

      user = Accounts.get_user_by_email("newcomer@example.com")
      {:ok, _} = Accounts.disable(user)

      refute Accounts.signup_allowed?("newcomer@example.com")
    end
  end

  describe "when it does not" do
    setup do: set_up(Map.merge(mail(), %{"invites_create_accounts" => false}))

    test "sharing with a stranger fails, and says why", %{alice: alice, board: board} do
      assert {:error, message} = Access.grant(board, "stranger@example.com", "read", alice)

      assert message =~ "No account here uses that address"
      assert message =~ "An admin can invite them"
    end

    test "and no ghost account is left behind", %{alice: alice, board: board} do
      {:error, _} = Access.grant(board, "stranger@example.com", "read", alice)

      # The old behaviour created the user and then granted; a failure part way
      # through would have left an account nobody meant to make.
      refute Accounts.get_user_by_email("stranger@example.com")
      refute Accounts.signup_allowed?("stranger@example.com")
    end

    test "sharing with somebody who is already here still works", %{alice: alice, board: board} do
      user_fixture("bob@example.com")
      assert {:ok, _} = Access.grant(board, "bob@example.com", "read", alice)
    end

    test "groups are governed too, not just boards", %{alice: alice} do
      {:ok, group} = Accounts.create_group(alice, %{"name" => "Design"})

      assert {:error, :invites_disabled} =
               Accounts.add_group_member(group, "stranger@example.com")

      refute Accounts.get_user_by_email("stranger@example.com")
    end
  end

  describe "with no mail server" do
    setup do: set_up(%{"invites_create_accounts" => true})

    test "the invitation falls back, and the caller is told which", %{alice: alice, board: board} do
      path =
        Path.join(System.tmp_dir!(), "slipdock-invite-#{System.unique_integer([:positive])}.log")

      previous_path = Application.get_env(:slipdock, :login_fallback_path)

      Application.put_env(:slipdock, :login_fallback_path, path)

      on_exit(fn ->
        Application.put_env(:slipdock, :login_fallback_path, previous_path)
        File.rm(path)
      end)

      {:ok, _} = Access.grant(board, "newcomer@example.com", "read", alice)

      # They exist, and the way in is somewhere the inviter can read it — an
      # account created in silence is worse than no account.
      assert Accounts.get_user_by_email("newcomer@example.com")
      assert File.read!(path) =~ "newcomer@example.com"
    end
  end
end
