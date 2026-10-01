defmodule Slipdock.AccountsTest do
  use Slipdock.DataCase, async: false

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
      assert email.subject =~ "sign-in link"
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
end
