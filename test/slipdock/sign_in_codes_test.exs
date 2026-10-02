defmodule Slipdock.SignInCodesTest do
  @moduledoc """
  The short code that opens the same door as the long link. Six digits is a
  small space, so most of this is about what stops it being walked.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.Accounts
  alias Slipdock.Accounts.UserToken

  defp request_code(email) do
    {:ok, _} = Accounts.deliver_magic_link(email, &"http://localhost/login/#{&1}")

    Repo.one!(
      from(t in UserToken,
        where: t.context == "magic" and t.sent_to == ^email,
        order_by: [desc: t.id],
        limit: 1
      )
    ).code
  end

  test "a code arrives with the link, and both say the same thing" do
    user_fixture("owner@example.com")
    code = request_code("owner@example.com")

    assert String.length(code) == 6
    assert code =~ ~r/^\d{6}$/

    assert_email_sent(fn email ->
      assert email.subject =~ code
      assert email.text_body =~ code
      # The link is still there: a code is an alternative, not a replacement.
      assert email.text_body =~ "http://localhost/login/"
    end)
  end

  test "the right code signs you in, and confirms the account" do
    user_fixture("owner@example.com")
    code = request_code("owner@example.com")

    assert {:ok, user} = Accounts.verify_sign_in_code("owner@example.com", code)
    assert user.email == "owner@example.com"
    assert user.confirmed_at
  end

  test "a code works once" do
    user_fixture("owner@example.com")
    code = request_code("owner@example.com")

    assert {:ok, _} = Accounts.verify_sign_in_code("owner@example.com", code)
    assert {:error, :invalid} = Accounts.verify_sign_in_code("owner@example.com", code)
  end

  test "using the code kills the link, since they are one row" do
    user_fixture("owner@example.com")
    {:ok, _} = Accounts.deliver_magic_link("owner@example.com", &"http://localhost/login/#{&1}")

    token =
      receive do
        {:email, email} ->
          [token] = Regex.run(~r{/login/([\w-]+)}, email.text_body, capture: :all_but_first)
          token
      after
        0 -> flunk("no email")
      end

    code = Repo.one!(from(t in UserToken, where: t.context == "magic")).code

    assert {:ok, _} = Accounts.verify_sign_in_code("owner@example.com", code)
    assert :error = Accounts.verify_magic_link(token)
  end

  test "somebody else's code is no use to you" do
    user_fixture("alice@example.com")
    user_fixture("bob@example.com")

    code = request_code("alice@example.com")

    # Codes are matched per address, which is what keeps the space at a million
    # per person rather than a million across the whole server.
    assert {:error, :invalid} = Accounts.verify_sign_in_code("bob@example.com", code)
  end

  test "a code dies after a handful of wrong guesses" do
    user_fixture("owner@example.com")
    code = request_code("owner@example.com")

    for _ <- 1..UserToken.code_attempt_limit() do
      assert {:error, _} = Accounts.verify_sign_in_code("owner@example.com", "000000")
    end

    assert {:error, :too_many} = Accounts.verify_sign_in_code("owner@example.com", "000000")
    # And the real code is dead too, not merely the guesses.
    assert {:error, :too_many} = Accounts.verify_sign_in_code("owner@example.com", code)
  end

  test "a fresh code works after an old one was guessed to death" do
    user_fixture("owner@example.com")
    request_code("owner@example.com")

    for _ <- 1..UserToken.code_attempt_limit() do
      Accounts.verify_sign_in_code("owner@example.com", "000000")
    end

    fresh = request_code("owner@example.com")

    # Deliberate. Carrying exhaustion across codes would lock out somebody who
    # simply mistyped, and it is not what bounds an attacker: asking for a code
    # is itself rate limited to five an hour per address, so the ceiling is
    # about twenty-five guesses an hour out of a million. The attempt counter
    # stops one code being walked; the request limiter stops many being asked
    # for. See `SlipdockWeb.LoginLive.Index`.
    assert {:ok, _} = Accounts.verify_sign_in_code("owner@example.com", fresh)
  end

  test "nonsense is refused without blowing up" do
    assert {:error, :invalid} = Accounts.verify_sign_in_code("nobody@example.com", "123456")
    assert {:error, :invalid} = Accounts.verify_sign_in_code("owner@example.com", "")
    assert {:error, :invalid} = Accounts.verify_sign_in_code(nil, "123456")
  end

  test "codes are random, not sequential" do
    user_fixture("owner@example.com")
    codes = for _ <- 1..20, do: request_code("owner@example.com")
    assert length(Enum.uniq(codes)) > 15
  end
end
