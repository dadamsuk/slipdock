defmodule Slipdock.SignupRequestsTest do
  @moduledoc """
  The `approval` registration mode: asking, being told, saying yes or no.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Accounts, Settings}

  defp approval_mode do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => "admin@example.com",
        "signup_mode" => :approval,
        "smtp_host" => "smtp.example.com",
        "smtp_from_email" => "mail@example.com"
      })

    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    %{admin: admin}
  end

  setup do: approval_mode()

  defp url_fun, do: &"http://localhost/login/#{&1}"

  test "asking records a request and tells the admin", %{admin: admin} do
    assert {:ok, request} =
             Accounts.request_signup("hopeful@example.com", note: "Design, starting Monday")

    assert request.status == "pending"
    assert request.note == "Design, starting Monday"

    assert_email_sent(fn email ->
      assert email.to == [{admin.email, admin.email}]
      assert email.subject =~ "hopeful@example.com"
      assert email.text_body =~ "Design, starting Monday"
    end)
  end

  test "asking does not create an account, which would approve it by asking" do
    {:ok, _} = Accounts.request_signup("hopeful@example.com")

    refute Accounts.get_user_by_email("hopeful@example.com")
    refute Accounts.signup_allowed?("hopeful@example.com")
  end

  test "asking twice does not pile up duplicates" do
    {:ok, _} = Accounts.request_signup("hopeful@example.com")
    assert {:ok, :already_pending} = Accounts.request_signup("hopeful@example.com")
    assert length(Accounts.list_signup_requests()) == 1
  end

  test "approving makes the account and sends them a way in", %{admin: admin} do
    {:ok, request} = Accounts.request_signup("hopeful@example.com")

    # Clear the admin notification so the next assertion is about the right mail.
    receive do
      {:email, _} -> :ok
    after
      0 -> :ok
    end

    assert {:ok, user} = Accounts.approve_signup(request, admin, url_fun())
    assert user.email == "hopeful@example.com"
    assert Accounts.signup_allowed?("hopeful@example.com")
    assert Accounts.list_signup_requests() == []

    # "Yes" is one action, not two with a gap in which nothing happens.
    assert_email_sent(fn email -> assert email.to == [{user.email, user.email}] end)
  end

  test "rejecting means no, and asking again does not reopen it", %{admin: admin} do
    {:ok, request} = Accounts.request_signup("nuisance@example.com")
    assert {:ok, _} = Accounts.reject_signup(request, admin)

    refute Accounts.signup_allowed?("nuisance@example.com")
    assert Accounts.list_signup_requests() == []

    # Otherwise "no" means "no until you ask again", and the queue becomes a
    # way to pester an admin indefinitely.
    assert {:error, :rejected} = Accounts.request_signup("nuisance@example.com")
  end

  test "somebody who already has an account has nothing to ask for" do
    user_fixture("member@example.com")
    assert {:error, :already_a_user} = Accounts.request_signup("member@example.com")
  end

  test "asking is refused outside approval mode" do
    {:ok, _} = Settings.update(%{"signup_mode" => :closed})
    assert {:error, :not_approval_mode} = Accounts.request_signup("hopeful@example.com")
  end

  test "a server with no admin says so rather than losing the request" do
    # The last admin cannot be demoted through any supported path, so this
    # reaches past the guard on purpose: the point is that a request must never
    # vanish silently, however the server got into that state.
    Repo.update_all(Slipdock.Accounts.User, set: [admin: false])
    assert {:ok, _} = Accounts.request_signup("hopeful@example.com")
    assert length(Accounts.list_signup_requests()) == 1
  end

  test "old decided requests are forgotten, pending ones are not", %{admin: admin} do
    {:ok, request} = Accounts.request_signup("old@example.com")
    {:ok, _} = Accounts.reject_signup(request, admin)

    long_ago = DateTime.utc_now() |> DateTime.add(-200, :day) |> DateTime.truncate(:second)

    Repo.update_all(Slipdock.Accounts.SignupRequest, set: [decided_at: long_ago])

    {:ok, _} = Accounts.request_signup("recent@example.com")

    assert Accounts.purge_signup_requests(90) == 1
    assert Enum.map(Accounts.list_signup_requests(), & &1.email) == ["recent@example.com"]
  end

  test "counting what is waiting, for a badge somewhere visible" do
    assert Accounts.count_pending_signups() == 0
    {:ok, _} = Accounts.request_signup("hopeful@example.com")
    assert Accounts.count_pending_signups() == 1
  end
end
