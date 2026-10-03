defmodule Slipdock.AdminStandingTest do
  @moduledoc """
  Admin rights, disabling an account, and the guards that stop a server being
  left with nobody who can administer it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Accounts

  describe "admin?/1" do
    test "is false for an ordinary user, nil, and anything else" do
      refute Accounts.admin?(user_fixture("someone@example.com"))
      refute Accounts.admin?(nil)
    end

    test "is true once promoted" do
      user = user_fixture("boss@example.com")
      assert {:ok, user} = Accounts.promote(user)
      assert Accounts.admin?(user)
      assert Accounts.count_admins() == 1
    end
  end

  describe "the last admin" do
    setup do
      {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
      %{admin: admin}
    end

    test "cannot be demoted", %{admin: admin} do
      assert Accounts.last_admin?(admin)
      assert {:error, :last_admin} = Accounts.demote(admin)
      assert Accounts.admin?(Repo.reload(admin))
    end

    test "cannot be disabled", %{admin: admin} do
      assert {:error, :last_admin} = Accounts.disable(admin)
      refute Accounts.disabled?(Repo.reload(admin))
    end

    test "can be demoted once there is a second admin", %{admin: admin} do
      {:ok, _other} = Accounts.promote(user_fixture("second@example.com"))

      refute Accounts.last_admin?(admin)
      assert {:ok, admin} = Accounts.demote(admin)
      refute Accounts.admin?(admin)
      assert Accounts.count_admins() == 1
    end

    test "an ordinary user is never the last admin" do
      refute Accounts.last_admin?(user_fixture("ordinary@example.com"))
    end
  end

  describe "disabling an account" do
    setup do
      # A second admin, so disabling the one under test is allowed.
      {:ok, _} = Accounts.promote(user_fixture("admin@example.com"))
      %{user: user_fixture("gone@example.com")}
    end

    test "ends their sessions there and then", %{user: user} do
      token = Accounts.generate_session_token(user)
      assert Accounts.get_user_by_session_token(token)

      assert {:ok, user} = Accounts.disable(user)
      assert Accounts.disabled?(user)
      # Both because the token was deleted and because a disabled user is not
      # returned even if one survived.
      refute Accounts.get_user_by_session_token(token)
    end

    test "stops their API tokens working", %{user: user} do
      {token, _} = Accounts.create_api_token(user, "a robot")
      assert Accounts.get_api_token(token)

      {:ok, _} = Accounts.disable(user)
      refute Accounts.get_api_token(token)
    end

    test "refuses them a sign-in link, whatever the registration mode says", %{user: user} do
      assert Accounts.signup_allowed?(user.email)
      {:ok, _} = Accounts.disable(user)
      refute Accounts.signup_allowed?(user.email)
    end

    test "is reversible, and they sign in again afterwards", %{user: user} do
      {:ok, user} = Accounts.disable(user)
      assert {:ok, user} = Accounts.enable(user)

      refute Accounts.disabled?(user)
      assert Accounts.signup_allowed?(user.email)

      token = Accounts.generate_session_token(user)
      assert Accounts.get_user_by_session_token(token)
    end
  end

  describe "update_standing/2" do
    test "sets a card limit of this person's own" do
      user = user_fixture("payer@example.com")
      assert {:ok, user} = Accounts.update_standing(user, %{"card_limit_override" => 500})
      assert user.card_limit_override == 500
    end

    test "refuses a limit of zero" do
      user = user_fixture("payer@example.com")
      assert {:error, changeset} = Accounts.update_standing(user, %{"card_limit_override" => 0})
      assert %{card_limit_override: [_ | _]} = errors_on(changeset)
    end

    test "cannot be reached through the profile form" do
      user = user_fixture("sneaky@example.com")
      {:ok, user} = Accounts.update_profile(user, %{"name" => "Sneaky", "admin" => true})

      assert user.name == "Sneaky"
      refute Accounts.admin?(user)
    end
  end

  describe "touch_last_signed_in/1" do
    test "records when somebody signed in" do
      user = user_fixture("visitor@example.com")
      refute user.last_signed_in_at

      assert :ok = Accounts.touch_last_signed_in(user)
      assert Repo.reload(user).last_signed_in_at
    end
  end
end
