defmodule Slipdock.AdminEmailTest do
  @moduledoc """
  Changing the server's admin address. The address everything is sent to — the
  approval notices, the warnings — so a typo is a silent lock-out, and a change
  nobody notices is a quiet takeover.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}
  alias Slipdock.Accounts.UserToken

  setup do
    {:ok, _} =
      Settings.complete_setup(%{
        "admin_email" => "old@example.com",
        "smtp_host" => "smtp.example.com",
        "smtp_from_email" => "mail@example.com"
      })

    {:ok, admin} = Accounts.promote(user_fixture("old@example.com"))
    %{admin: admin}
  end

  defp code do
    Repo.one!(from(t in UserToken, where: t.context == "admin_email")).code
  end

  test "the new address gets a code, and nothing changes yet", %{admin: admin} do
    assert {:ok, :sent} = Accounts.request_admin_email_change("new@example.com", admin)

    # Still the old one: a new address has to prove it can receive mail before
    # it becomes the one everything is sent to.
    assert Settings.get().admin_email == "old@example.com"

    # Two messages go out (the new address and the old one), so match on the
    # mailbox rather than on "the first email", which is whichever won the race.
    expected = code()
    assert_received {:email, %Swoosh.Email{to: [{_, "new@example.com"}], text_body: body}}
    assert body =~ expected
  end

  test "the old address is warned, so a quiet takeover is not quiet", %{admin: admin} do
    {:ok, :sent} = Accounts.request_admin_email_change("new@example.com", admin)

    assert_received {:email, %Swoosh.Email{to: [{_, "old@example.com"}], subject: subject}}
    assert subject =~ "changing your Slipdock admin address"
  end

  test "confirming the code moves it, and makes that person an admin", %{admin: admin} do
    {:ok, :sent} = Accounts.request_admin_email_change("new@example.com", admin)

    assert {:ok, "new@example.com"} = Accounts.confirm_admin_email_change(code(), admin)
    assert Settings.get().admin_email == "new@example.com"

    # Otherwise the address everything is sent to belongs to somebody who
    # cannot sign in and do anything about it.
    assert Accounts.admin?(Accounts.get_user_by_email("new@example.com"))
  end

  test "a wrong code changes nothing", %{admin: admin} do
    {:ok, :sent} = Accounts.request_admin_email_change("new@example.com", admin)

    assert {:error, :invalid} = Accounts.confirm_admin_email_change("000000", admin)
    assert Settings.get().admin_email == "old@example.com"
  end

  test "guessing at the code stops after a handful of tries", %{admin: admin} do
    previous = Application.get_env(:slipdock, :rate_limit)
    Application.put_env(:slipdock, :rate_limit, enabled: true)
    Slipdock.RateLimit.reset()
    on_exit(fn -> Application.put_env(:slipdock, :rate_limit, previous) end)

    {:ok, :sent} = Accounts.request_admin_email_change("new@example.com", admin)

    for _ <- 1..5,
        do: assert({:error, :invalid} = Accounts.confirm_admin_email_change("1", admin))

    # Even the right code is refused now: the limit is on trying, not on failing.
    assert {:error, :too_many_attempts} = Accounts.confirm_admin_email_change(code(), admin)
    assert Settings.get().admin_email == "old@example.com"
  end

  test "a code works once", %{admin: admin} do
    {:ok, :sent} = Accounts.request_admin_email_change("new@example.com", admin)
    c = code()

    assert {:ok, _} = Accounts.confirm_admin_email_change(c, admin)
    assert {:error, :invalid} = Accounts.confirm_admin_email_change(c, admin)
  end

  test "somebody else's code is no use", %{admin: admin} do
    {:ok, other} = Accounts.promote(user_fixture("other@example.com"))
    {:ok, :sent} = Accounts.request_admin_email_change("new@example.com", admin)

    assert {:error, :invalid} = Accounts.confirm_admin_email_change(code(), other)
  end

  test "refuses without a mail server, which is the whole mechanism", %{admin: admin} do
    {:ok, _} = Settings.update(%{"smtp_host" => nil, "smtp_from_email" => nil})

    assert {:error, message} = Accounts.request_admin_email_change("new@example.com", admin)
    assert message =~ "mail server"
  end

  test "refuses nonsense and the address it already is", %{admin: admin} do
    assert {:error, _} = Accounts.request_admin_email_change("not an address", admin)
    assert {:error, message} = Accounts.request_admin_email_change("old@example.com", admin)
    assert message =~ "already"
  end
end
