defmodule Slipdock.AccountsTest do
  use Slipdock.DataCase, async: true

  import Swoosh.TestAssertions
  alias Slipdock.Accounts
  alias Slipdock.Accounts.{User, UserToken}
  alias Slipdock.Repo

  test "magic link: email, verify once, then session tokens for 30 days" do
    assert {:ok, _} =
             Accounts.deliver_magic_link("  New.Person@Example.com ", &("https://k/login/" <> &1))

    assert %User{email: "new.person@example.com", confirmed_at: nil} =
             user = Accounts.get_user_by_email("new.person@example.com")

    assert_email_sent(fn email ->
      assert email.subject =~ "sign-in code"
      [token] = Regex.run(~r{https://k/login/([\w-]+)}, email.text_body, capture: :all_but_first)
      assert {:ok, %User{id: id, confirmed_at: %DateTime{}}} = Accounts.verify_magic_link(token)
      assert id == user.id
      # Single use.
      assert :error = Accounts.verify_magic_link(token)
    end)

    assert :error = Accounts.verify_magic_link("not-a-token")

    # Sessions expire after 30 days.
    token = Accounts.generate_session_token(user)
    assert Accounts.get_user_by_session_token(token).id == user.id

    Repo.update_all(UserToken.by_token_and_context(token, "session"),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -31, :day)]
    )

    assert is_nil(Accounts.get_user_by_session_token(token))

    token = Accounts.generate_session_token(user)
    :ok = Accounts.delete_session_token(token)
    assert is_nil(Accounts.get_user_by_session_token(token))
  end

  test "expired magic links are refused" do
    {:ok, user} = Accounts.get_or_create_user_by_email("late@example.com")
    {token, user_token} = UserToken.build_hashed_token(user, "magic", sent_to: user.email)

    Repo.insert!(%{
      user_token
      | inserted_at: DateTime.add(DateTime.utc_now(:second), -20, :minute)
    })

    assert :error = Accounts.verify_magic_link(token)
  end

  test "api tokens" do
    {:ok, user} = Accounts.get_or_create_user_by_email("api@example.com")
    {token, record} = Accounts.create_api_token(user, "laptop")
    assert Accounts.get_user_by_api_token(token).id == user.id
    assert [%{label: "laptop", last_used_at: %DateTime{}}] = Accounts.list_api_tokens(user)
    assert is_nil(Accounts.get_user_by_api_token("bogus"))
    :ok = Accounts.delete_api_token(user, record.id)
    assert is_nil(Accounts.get_user_by_api_token(token))
  end

  test "only an admin can mint an admin-scope token" do
    {:ok, user} = Accounts.get_or_create_user_by_email("plain@example.com")

    # A forged form post asking for admin gets an ordinary token, not a dormant
    # admin one waiting for its owner to be promoted.
    {_token, record} = Accounts.create_api_token(user, "sneaky", scope: "admin")
    assert record.scope == "write"

    {:ok, admin} = Accounts.promote(user)
    {_token, record} = Accounts.create_api_token(admin, "deliberate", scope: "admin")
    assert record.scope == "admin"

    {_token, record} = Accounts.create_api_token(admin, "odd", scope: "root")
    assert record.scope == "write"
  end

  test "groups and members" do
    {:ok, owner} = Accounts.get_or_create_user_by_email("owner@example.com")
    {:ok, group} = Accounts.create_group(owner, %{"name" => "Team"})
    assert {:error, cs} = Accounts.create_group(owner, %{"name" => "Team "})
    assert cs.errors[:name]

    {:ok, group} = Accounts.add_group_member(group, "member@example.com")
    member = Accounts.get_user_by_email("member@example.com")
    assert Enum.map(group.members, & &1.id) == [member.id]
    assert Accounts.group_ids_for(member) == [group.id]
    assert Enum.map(Accounts.list_groups(member), & &1.id) == [group.id]
    assert Accounts.group_member?(group, member) and Accounts.group_member?(group, owner)

    {:ok, group} = Accounts.remove_group_member(group, member)
    assert group.members == []
    assert Accounts.list_groups(member) == []
  end

  describe "change_email/3" do
    test "the old address is told, and a link sent to it stops working" do
      {:ok, _} =
        Slipdock.Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => Slipdock.Fixtures.fixture_email("mail@example.com")
        })

      admin = Slipdock.Fixtures.user_fixture("boss@example.com")
      user = Slipdock.Fixtures.user_fixture("moving@example.com")
      old = user.email
      token = Accounts.create_sign_in_token(user)
      new = Slipdock.Fixtures.fixture_email("moved@example.com")

      assert {:ok, %User{email: ^new}} =
               Accounts.change_email(user, " " <> String.upcase(new), admin)

      assert_email_sent(fn email ->
        assert email.to == [{"", old}]
        assert email.subject == "Your Slipdock address has been changed"
        assert email.text_body =~ new
      end)

      assert :error = Accounts.verify_magic_link(token)
    end

    test "an unchanged address sends nothing" do
      admin = Slipdock.Fixtures.user_fixture("boss2@example.com")
      user = Slipdock.Fixtures.user_fixture("staying@example.com")

      assert {:ok, _} = Accounts.change_email(user, user.email, admin)
      refute_email_sent()
    end
  end

  describe "add_user/2" do
    test "is not gated on invites_create_accounts, and refuses an existing address" do
      {:ok, _} = Slipdock.Settings.update(%{"invites_create_accounts" => false})
      admin = Slipdock.Fixtures.user_fixture("boss3@example.com")
      email = Slipdock.Fixtures.fixture_email("added@example.com")

      assert {:ok, %User{invited_by_id: invited_by}, _delivery} = Accounts.add_user(email, admin)
      assert invited_by == admin.id
      assert {:error, :exists} = Accounts.add_user(String.upcase(email), admin)
    end
  end
end
