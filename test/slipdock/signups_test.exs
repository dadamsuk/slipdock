defmodule Slipdock.SignupsTest do
  @moduledoc """
  Who is allowed an account, and the counters that stop the sign-in form being
  used as a mailer. Both are off or open in the test environment by default
  (every other test signs in whoever it likes), so these turn them on.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, RateLimit}

  # Registration policy is a row now, not configuration. Setting it means
  # setting the server up, which is also what closes the "anybody may sign in
  # to an unclaimed instance" door — so these are one helper.
  defp mode(mode, allow \\ []) do
    # Approval mode is refused without a mail server, deliberately — nobody
    # would be told that somebody is waiting.
    mail =
      if mode == :approval,
        do: %{"smtp_host" => "smtp.example.com", "smtp_from_email" => "mail@example.com"},
        else: %{}

    {:ok, _} =
      Slipdock.Settings.complete_setup(
        Map.merge(mail, %{"admin_email" => "admin@example.com", "signup_mode" => mode})
      )

    for entry <- allow, do: {:ok, _} = Slipdock.Settings.add_allowlist_entry(entry)
    :ok
  end

  # The test environment calls itself already set up, so that the wizard does
  # not intercept every other test. These two say otherwise.
  defp unclaimed_instance do
    settings(setup_completed: false)
  end

  defp settings(opts) do
    previous = Application.get_env(:slipdock, :settings)
    Application.put_env(:slipdock, :settings, opts)
    on_exit(fn -> Application.put_env(:slipdock, :settings, previous) end)
  end

  describe "the admin's own address" do
    test "is never refused, even with registration closed" do
      # Otherwise an install whose admin address has no account yet — what
      # SLIPDOCK_ADMIN_EMAIL used to leave behind — has no way in at all.
      mode(:closed)

      refute Accounts.get_user_by_email("admin@example.com")
      assert Accounts.signup_allowed?("admin@example.com")
      assert Accounts.signup_allowed?("Admin@Example.com")
      refute Accounts.signup_allowed?("somebody@example.com")
    end

    test "is still refused once it is disabled" do
      mode(:closed)
      admin = user_fixture("admin@example.com")
      {:ok, _} = Accounts.promote(admin)
      other = user_fixture("second@example.com")
      {:ok, _} = Accounts.promote(other)
      {:ok, _} = Accounts.disable(admin)

      refute Accounts.signup_allowed?("admin@example.com")
    end
  end

  describe "a server nobody has set up" do
    setup do
      unclaimed_instance()
      :ok
    end

    test "lets anybody in, because the wizard needs a way through" do
      refute Slipdock.Settings.setup_complete?()

      assert Accounts.signup_allowed?("first@example.com")
      assert Accounts.signup_allowed?("anybody@example.com")
    end

    test "is still unclaimed even when it has users" do
      # A user can exist without anybody having been through setup: sharing a
      # board with an address creates one. Counting users was the wrong
      # question, which is why this reads setup_completed_at instead.
      user_fixture("invited@example.com")

      assert Accounts.count_users() == 1
      assert Accounts.signup_allowed?("stranger@example.com")
    end
  end

  describe "signup_allowed?/1 when registration is closed" do
    setup do
      mode(:closed)
    end

    test "once the server has been set up, a new address is refused" do
      refute Accounts.signup_allowed?("second@example.com")
    end

    test "once somebody is here, a stranger is not" do
      # The test environment counts as set up, so the claim rule is not in play.
      user_fixture("owner@example.com")
      refute Accounts.signup_allowed?("stranger@example.com")
      # ...but the person who is already here always can.
      assert Accounts.signup_allowed?("owner@example.com")
      assert Accounts.signup_allowed?("  OWNER@Example.com  ")
    end

    test "a blank address is not an address" do
      user_fixture("owner@example.com")
      refute Accounts.signup_allowed?("")
      refute Accounts.signup_allowed?(nil)
    end

    test "no link is sent to an address that may not sign up, and it is not created" do
      user_fixture("owner@example.com")

      assert {:error, :not_allowed} =
               Accounts.deliver_magic_link("stranger@example.com", & &1)

      assert Accounts.get_user_by_email("stranger@example.com") == nil
      assert Accounts.count_users() == 1
    end

    test "agentic login obeys the same gate, so it is not a way round it" do
      user_fixture("owner@example.com")
      assert {:error, :not_allowed} = Accounts.write_agentic_login("stranger@example.com", & &1)
    end
  end

  describe "signup_allowed?/1 under the allowlist mode" do
    test "an address on the list, or anyone at a listed domain" do
      user_fixture("owner@example.com")
      mode(:allowlist, ["friend@elsewhere.com", "@work.example", "Other.Example"])

      assert Accounts.signup_allowed?("friend@elsewhere.com")
      assert Accounts.signup_allowed?("anyone@work.example")
      assert Accounts.signup_allowed?("ANYONE@Other.Example")
      refute Accounts.signup_allowed?("nobody@elsewhere.com")
    end

    test "a link does go to an allowed stranger, and makes their account" do
      user_fixture("owner@example.com")
      mode(:allowlist, ["@work.example"])

      assert {:ok, _} = Accounts.deliver_magic_link("new@work.example", &"/login/#{&1}")
      assert Accounts.get_user_by_email("new@work.example")
    end
  end

  describe "signup_allowed?/1 under the other modes" do
    test "open lets anybody in" do
      user_fixture("owner@example.com")
      mode(:open)
      assert Accounts.signup_allowed?("stranger@example.com")
      assert Accounts.signups_open?()
      assert Accounts.signup_stance() == :open
    end

    test "approval refuses for now — asking is a separate thing" do
      user_fixture("owner@example.com")
      mode(:approval)

      # Not allowed *yet*: `request_signup/1` is how somebody asks, and an
      # admin saying yes is what changes this answer.
      refute Accounts.signup_allowed?("stranger@example.com")
      refute Accounts.signups_open?()
      assert Accounts.signup_stance() == :approval
    end

    test "an unclaimed server reports itself as such, so the page can say so" do
      unclaimed_instance()
      assert Accounts.signup_stance() == :unclaimed
      assert Accounts.signups_open?()
    end
  end

  describe "the sign-in limiter" do
    setup do
      previous = Application.get_env(:slipdock, :rate_limit)
      Application.put_env(:slipdock, :rate_limit, enabled: true)
      RateLimit.reset()

      on_exit(fn ->
        Application.put_env(:slipdock, :rate_limit, previous)
        RateLimit.reset()
      end)
    end

    test "is keyed on the normalised address, so casing cannot multiply the allowance" do
      # Five an hour per address. If the key were the raw string, "A@x", "a@x"
      # and " a@x " would be three separate allowances and the limit would mean
      # nothing.
      key = fn email -> "login:email:" <> (email |> String.trim() |> String.downcase()) end

      for _ <- 1..5, do: assert(:ok = RateLimit.hit(key.("Owner@Example.com"), 5, 3_600_000))

      assert {:error, _} = RateLimit.hit(key.("  owner@example.com  "), 5, 3_600_000)
      assert {:error, _} = RateLimit.hit(key.("OWNER@EXAMPLE.COM"), 5, 3_600_000)
    end
  end

  describe "Slipdock.RateLimit" do
    setup do
      previous = Application.get_env(:slipdock, :rate_limit)
      Application.put_env(:slipdock, :rate_limit, enabled: true)
      RateLimit.reset()

      on_exit(fn ->
        Application.put_env(:slipdock, :rate_limit, previous)
        RateLimit.reset()
      end)

      %{key: "test:#{System.unique_integer([:positive])}"}
    end

    test "allows up to the limit and then refuses, saying when to come back", ctx do
      window = :timer.hours(1)
      for _ <- 1..3, do: assert(:ok = RateLimit.hit(ctx.key, 3, window))

      assert {:error, seconds} = RateLimit.hit(ctx.key, 3, window)
      assert seconds > 0
      assert seconds <= 3601
    end

    test "counts each key separately", ctx do
      assert :ok = RateLimit.hit(ctx.key, 1, :timer.hours(1))
      assert {:error, _} = RateLimit.hit(ctx.key, 1, :timer.hours(1))
      assert :ok = RateLimit.hit(ctx.key <> ":other", 1, :timer.hours(1))
    end

    test "remaining/3 reports without spending", ctx do
      assert RateLimit.remaining(ctx.key, 5, :timer.hours(1)) == 5
      assert :ok = RateLimit.hit(ctx.key, 5, :timer.hours(1))
      assert RateLimit.remaining(ctx.key, 5, :timer.hours(1)) == 4
      assert RateLimit.remaining(ctx.key, 5, :timer.hours(1)) == 4
    end

    test "a new window forgives", ctx do
      # A one-millisecond window has certainly rolled over by the next line.
      assert :ok = RateLimit.hit(ctx.key, 1, 1)
      Process.sleep(2)
      assert :ok = RateLimit.hit(ctx.key, 1, 1)
    end

    test "disabled, it allows everything", ctx do
      Application.put_env(:slipdock, :rate_limit, enabled: false)
      for _ <- 1..50, do: assert(:ok = RateLimit.hit(ctx.key, 1, :timer.hours(1)))
    end
  end
end
