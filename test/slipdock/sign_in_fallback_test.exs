defmodule Slipdock.SignInFallbackTest do
  @moduledoc """
  The file sign-in codes go to when no mail server can carry them — the thing
  that lets a fresh install be used at all, and a back door on a server other
  people can reach.
  """
  # Sync: changes the Logger level, which is the whole node's.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Settings}

  setup do
    path =
      Path.join(System.tmp_dir!(), "slipdock-fallback-#{System.unique_integer([:positive])}.log")

    previous_path = Application.get_env(:slipdock, :login_fallback_path)

    Application.put_env(:slipdock, :login_fallback_path, path)

    on_exit(fn ->
      Application.put_env(:slipdock, :login_fallback_path, previous_path)
      Application.delete_env(:slipdock, :login_fallback)
      File.rm(path)
    end)

    %{path: path, user: user_fixture("owner@example.com")}
  end

  defp deliver(user), do: Accounts.deliver_sign_in(user, &"http://localhost/login/#{&1}")

  defp ask_from_login_page(email),
    do: Accounts.deliver_magic_link(email, &"http://localhost/login/#{&1}")

  # config/test.exs pins the logger at :warning, which would hide exactly the
  # `Logger.info` these tests are looking for.
  defp capture_info(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    ExUnit.CaptureLog.capture_log(fun)
  end

  defp smtp_on do
    {:ok, _} =
      Settings.update(%{"smtp_host" => "smtp.example.com", "smtp_from_email" => "m@example.com"})
  end

  # The token is the path segment after /login/; the code is the six digits
  # in the subject of the message the test adapter received.
  defp sent_secrets do
    assert_received {:email, %Swoosh.Email{subject: subject, text_body: body}}
    [_, token] = Regex.run(~r{/login/(\S+)}, body)
    [code] = Regex.run(~r/\d{6}/, subject)
    {token, code}
  end

  test "with no mail server, the code and the link go to one known file", %{
    user: user,
    path: path
  } do
    assert {:ok, {:written, ^path}} = deliver(user)

    line = File.read!(path)
    assert line =~ "owner@example.com"
    assert line =~ "http://localhost/login/"
    assert line =~ ~r/\s\d{6}\s/
  end

  test "the file is readable only by the user running the server", %{user: user, path: path} do
    {:ok, _} = deliver(user)

    # Anyone who can read it can sign in as anybody, so it must not be world
    # readable even for a moment.
    %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "it appends, so an earlier code is not lost", %{user: user, path: path} do
    {:ok, _} = deliver(user)
    {:ok, _} = deliver(user)

    assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 2
  end

  test "a working mail server is used instead, and nothing is written", %{
    user: user,
    path: path
  } do
    {:ok, _} =
      Settings.update(%{"smtp_host" => "smtp.example.com", "smtp_from_email" => "m@example.com"})

    assert {:ok, :emailed} = deliver(user)
    refute File.exists?(path)
  end

  test "an admin can turn it off, and then there is no delivery at all", %{
    user: user,
    path: path
  } do
    {:ok, _} = Settings.update(%{"login_fallback_enabled" => false})

    assert {:error, :no_delivery} = deliver(user)
    refute File.exists?(path)
  end

  test "the config override forbids it whatever the settings say", %{user: user, path: path} do
    # What a public host sets. The application must not be able to undo it, so
    # even an admin explicitly enabling it changes nothing.
    Application.put_env(:slipdock, :login_fallback, false)
    {:ok, _} = Settings.update(%{"login_fallback_enabled" => true})

    refute Settings.login_fallback_enabled?()
    assert {:error, :no_delivery} = deliver(user)
    refute File.exists?(path)
  end

  test "it is on by default only while there is no mail server" do
    refute Settings.smtp_configured?()
    assert Settings.login_fallback_enabled?()

    {:ok, _} =
      Settings.update(%{"smtp_host" => "smtp.example.com", "smtp_from_email" => "m@example.com"})

    # Once mail works the back door closes itself, without anybody deciding to.
    refute Settings.login_fallback_enabled?()
  end

  describe "the log never holds a way in" do
    test "a sign-in mailed from the login page", %{path: path} do
      smtp_on()

      log = capture_info(fn -> assert {:ok, _} = ask_from_login_page("owner@example.com") end)

      {token, code} = sent_secrets()
      refute log =~ token
      refute log =~ code
      refute File.exists?(path)
    end

    test "a sign-in mailed by the setup wizard or an invitation", %{user: user} do
      smtp_on()

      log = capture_info(fn -> assert {:ok, :emailed} = deliver(user) end)

      {token, code} = sent_secrets()
      refute log =~ token
      refute log =~ code
    end

    test "no mail and the fallback switched off", %{path: path} do
      {:ok, _} = Settings.update(%{"login_fallback_enabled" => false})

      log = capture_info(fn -> assert {:ok, _} = ask_from_login_page("owner@example.com") end)

      {token, code} = sent_secrets()
      refute log =~ token
      refute log =~ code
      refute File.exists?(path)
    end

    test "the admin-address code", %{user: user} do
      smtp_on()

      log =
        capture_info(fn ->
          assert {:ok, :sent} = Accounts.request_admin_email_change("new@example.com", user)
        end)

      assert_received {:email, %Swoosh.Email{to: [{_, "new@example.com"}], subject: subject}}
      [code] = Regex.run(~r/\d{6}/, subject)
      refute log =~ code
    end
  end

  test "with no mail and the fallback on, the login page writes the fallback", %{path: path} do
    # The only way into a fresh install that has no mail server: what the
    # notifier used to log on every delivery now comes from here, and only here.
    log = capture_info(fn -> assert {:ok, _} = ask_from_login_page("owner@example.com") end)

    {token, code} = sent_secrets()
    line = File.read!(path)
    assert line =~ token
    assert line =~ code
    assert log =~ code
  end
end
