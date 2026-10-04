defmodule Slipdock.MailerTest do
  @moduledoc """
  Building the mail adapter from the settings row rather than from boot config,
  and turning gen_smtp's failures into something an admin can act on.
  """
  use Slipdock.DataCase, async: false

  alias Slipdock.{Mailer, Settings}

  defp from_settings(value) do
    previous = Application.get_env(:slipdock, :mailer_from_settings)
    Application.put_env(:slipdock, :mailer_from_settings, value)
    on_exit(fn -> Application.put_env(:slipdock, :mailer_from_settings, previous) end)
  end

  describe "tls_options/1" do
    test "verifies the relay's certificate and its name by default" do
      opts = Mailer.tls_options("smtp.example.com")
      assert opts[:verify] == :verify_peer
      assert opts[:server_name_indication] == ~c"smtp.example.com"
      assert [_ | _] = opts[:cacerts]
      assert [match_fun: fun] = opts[:customize_hostname_check]
      assert is_function(fun)
    end

    test "SLIPDOCK_SMTP_TLS_VERIFY=false is the opt-out for a self-signed relay" do
      previous = Application.get_env(:slipdock, :smtp_tls_verify)
      Application.put_env(:slipdock, :smtp_tls_verify, false)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:slipdock, :smtp_tls_verify),
          else: Application.put_env(:slipdock, :smtp_tls_verify, previous)
      end)

      assert Mailer.tls_options("smtp.example.com") == [verify: :verify_none]
    end
  end

  describe "settings_config/1" do
    test "is empty when no mail server is configured, so the compiled adapter stands" do
      from_settings(true)
      assert Mailer.settings_config() == []
    end

    test "builds an SMTP adapter from the stored settings" do
      from_settings(true)

      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_port" => 2525,
          "smtp_from_email" => "mail@example.com",
          "smtp_tls" => :always
        })

      config = Mailer.settings_config()
      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 2525
      assert config[:tls] == :always
      # No credentials given, so none are offered: an IP-authorised relay
      # refuses a connection that presents empty ones.
      assert config[:auth] == :never
      # The relay is verified, and against the name it was configured by.
      assert config[:tls_options][:verify] == :verify_peer
      assert config[:tls_options][:server_name_indication] == ~c"smtp.example.com"
    end

    test "offers credentials only when both are there" do
      from_settings(true)

      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "mail@example.com",
          "smtp_username" => "someone",
          "smtp_password" => "secret"
        })

      config = Mailer.settings_config()
      assert config[:auth] == :always
      assert config[:username] == "someone"
      assert config[:password] == "secret"
    end

    test "defaults the port, so a host on its own is enough" do
      from_settings(true)

      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "m@example.com"
        })

      assert Mailer.settings_config()[:port] == 587
    end

    test "reads nothing from the settings when told not to" do
      from_settings(false)

      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "m@example.com"
        })

      assert Mailer.settings_config() == []
    end
  end

  describe "from/0" do
    test "prefers the stored sender" do
      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "board@example.com",
          "smtp_from_name" => "The Board"
        })

      assert Mailer.from() == {"The Board", "board@example.com"}
    end

    test "falls back to the configured sender when nothing is stored" do
      assert Mailer.from() == Application.get_env(:slipdock, :mail_from)
    end
  end

  describe "test_delivery/2" do
    test "refuses before there is anything to test" do
      assert {:error, message} = Mailer.test_delivery(%{}, "admin@example.com")
      assert message =~ "mail server's address"
    end

    test "refuses without a sender, which a relay would reject anyway" do
      assert {:error, message} =
               Mailer.test_delivery(%{"smtp_host" => "smtp.example.com"}, "admin@example.com")

      assert message =~ "come from"
    end

    test "sends with values that have not been saved" do
      assert :ok =
               Mailer.test_delivery(
                 %{"smtp_host" => "smtp.example.com", "smtp_from_email" => "mail@example.com"},
                 "admin@example.com"
               )

      assert_received {:email, %Swoosh.Email{subject: "Slipdock can send mail"}}
      # Nothing was stored: a test send must not be a way to save a bad config.
      refute Settings.smtp_configured?()
    end

    test "a blank password means the stored one, which the browser never saw" do
      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => "mail@example.com",
          "smtp_username" => "someone",
          "smtp_password" => "secret"
        })

      from_settings(true)

      # Re-testing with the password field left empty still authenticates.
      assert Mailer.settings_config()[:password] == "secret"
    end
  end

  describe "describe_error/1" do
    test "names the thing an admin can actually fix" do
      assert Mailer.describe_error(
               {:error, {:retries_exceeded, {:network_failure, ~c"h", {:error, :nxdomain}}}}
             ) =~ "No server found"

      assert Mailer.describe_error(
               {:error, {:retries_exceeded, {:network_failure, ~c"h", {:error, :econnrefused}}}}
             ) =~ "refused the connection"

      assert Mailer.describe_error({:error, {:authentication_failed, "535 nope"}}) =~
               "username or password"

      assert Mailer.describe_error(:no_credentials) =~ "username and password"
    end

    test "says something, whatever it is handed" do
      assert is_binary(Mailer.describe_error(:something_new))
      assert Mailer.describe_error({:error, :wat}) =~ "Mail could not be sent"
    end
  end
end
