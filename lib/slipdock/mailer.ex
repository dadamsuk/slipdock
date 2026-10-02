defmodule Slipdock.Mailer do
  @moduledoc """
  How mail leaves this server.

  Swoosh normally takes its adapter from application config, read once at boot
  — which is why the SMTP details used to be `SLIPDOCK_SMTP_*` and could not be
  changed without a redeploy. They live in the settings row now (see
  `Slipdock.Settings`), so the adapter has to be built per delivery instead:
  `deliver_configured/1` does that, and every caller in the app uses it rather
  than `deliver/1`.

  Three consequences worth knowing:

    * With no SMTP host configured, nothing is overridden and the compiled
      adapter stands — `Swoosh.Adapters.Local` in development, the test adapter
      under test. That is what makes a fresh install work at all.
    * `test_delivery/2` can send with values that have **not** been saved,
      which is what lets the setup wizard and the admin page insist on a
      successful test send before they will store a configuration. Saving a
      broken SMTP configuration as the only way to sign in would lock everyone
      out permanently, so this is the guard that matters most here.
    * `config :slipdock, :mailer_from_settings, false` stops settings being
      read at all. The test environment sets it, so no test can accidentally
      build a real SMTP adapter and post mail to the internet.
  """
  use Swoosh.Mailer, otp_app: :slipdock

  require Logger

  alias Slipdock.Settings
  alias Slipdock.Settings.Instance

  @doc """
  Sends `email` using the stored SMTP settings when there are any, and the
  compiled adapter when there are not.
  """
  def deliver_configured(email) do
    case settings_config() do
      [] -> deliver(email)
      config -> deliver(email, config)
    end
  end

  @doc """
  Sends a test message to `recipient` using `attrs` — SMTP settings straight
  from a form, not yet saved. Returns `:ok`, or `{:error, message}` with
  something a person can act on.

  `attrs` takes the same string keys the settings form uses
  (`"smtp_host"`, `"smtp_port"`, `"smtp_username"`, `"smtp_password"`,
  `"smtp_tls"`, `"smtp_from_email"`, `"smtp_from_name"`). A blank password
  means "whatever is stored", so an admin re-testing an existing configuration
  does not have to retype a secret the browser was never shown.
  """
  @spec test_delivery(map(), String.t()) :: :ok | {:error, String.t()}
  def test_delivery(attrs, recipient) when is_map(attrs) and is_binary(recipient) do
    instance = instance_from(attrs)

    cond do
      not Settings.smtp_configured?(instance) ->
        {:error, "Fill in the mail server's address first."}

      is_nil(instance.smtp_from_email) ->
        {:error, "Fill in the address mail should come from first."}

      true ->
        instance |> test_email(recipient) |> send_test(instance)
    end
  end

  @doc """
  The adapter configuration the stored settings imply, or `[]` when mail is not
  configured here and the compiled adapter should stand.
  """
  @spec settings_config(Instance.t() | nil) :: keyword()
  def settings_config(instance \\ nil) do
    instance = instance || Settings.get()

    if from_settings?() and Settings.smtp_configured?(instance) do
      [
        adapter: Swoosh.Adapters.SMTP,
        relay: instance.smtp_host,
        port: instance.smtp_port || 587,
        tls: instance.smtp_tls || :if_available,
        # The relay's certificate is not verified. That is the same choice this
        # made when it was environment configuration, and changing it would
        # break every self-signed internal relay in use; a verified option
        # belongs on its own setting rather than as a silent default.
        tls_options: [verify: :verify_none],
        retries: 1
      ] ++ auth(instance)
    else
      []
    end
  end

  @doc """
  Who mail comes from: the stored sender if there is one, else the
  `:mail_from` config this used before any of it was editable.
  """
  @spec from() :: {String.t(), String.t()} | String.t()
  def from do
    instance = Settings.get()

    if instance.smtp_from_email do
      {instance.smtp_from_name || "Slipdock", instance.smtp_from_email}
    else
      Application.get_env(:slipdock, :mail_from, {"Slipdock", "slipdock@localhost"})
    end
  end

  @doc """
  Turns a delivery failure into something worth showing somebody. SMTP errors
  arrive as nested tuples from `gen_smtp` and are unreadable as they stand, and
  "mail could not be sent" on its own gives an admin nothing to fix.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:error, reason}), do: describe_error(reason)

  def describe_error({:retries_exceeded, {:network_failure, _, {:error, :nxdomain}}}),
    do: "No server found at that address — check the hostname."

  def describe_error({:retries_exceeded, {:network_failure, _, {:error, :econnrefused}}}),
    do: "That server refused the connection — check the port."

  def describe_error({:retries_exceeded, {:network_failure, _, {:error, :etimedout}}}),
    do: "Timed out reaching that server. A firewall between here and it is the usual cause."

  def describe_error({:retries_exceeded, {:temporary_failure, _, reason}}),
    do: "The server would not accept the message: #{printable(reason)}"

  def describe_error({:no_more_hosts, {:permanent_failure, _, reason}}),
    do: "The server rejected it: #{printable(reason)}"

  def describe_error({:permanent_failure, _, reason}),
    do: "The server rejected it: #{printable(reason)}"

  def describe_error({:authentication_failed, reason}),
    do: "The username or password was refused: #{printable(reason)}"

  # Unwrapped by the `{:error, reason}` clause above before it reaches here.
  def describe_error(:no_credentials), do: "That server wants a username and password."

  def describe_error(reason), do: "Mail could not be sent: #{printable(reason)}"

  ## Internals

  defp send_test(email, instance) do
    case deliver(email, settings_config(instance)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Test message failed: #{inspect(reason)}")
        {:error, describe_error(reason)}
    end
  rescue
    # gen_smtp raises on some malformed configurations rather than returning an
    # error, and a test send is exactly where that must not take the page down.
    error -> {:error, describe_error(error)}
  end

  defp test_email(%Instance{} = instance, recipient) do
    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient)
    |> Swoosh.Email.from({instance.smtp_from_name || "Slipdock", instance.smtp_from_email})
    |> Swoosh.Email.subject("Slipdock can send mail")
    |> Swoosh.Email.text_body("""
    This is the test message from Slipdock's mail settings.

    If you are reading it, sign-in codes and automation emails will reach
    people, and you can save these settings.
    """)
  end

  # Credentials are optional: an IP-authorised relay (Gmail's
  # smtp-relay.gmail.com, say) needs none, and passing empty ones to one makes
  # it refuse the connection.
  defp auth(%Instance{smtp_username: user, smtp_password: pass})
       when is_binary(user) and user != "" and is_binary(pass) and pass != "" do
    [username: user, password: pass, auth: :always]
  end

  defp auth(_), do: [auth: :never]

  # A form's values over what is stored, except for a blank password, which
  # means "keep the one you have" — the browser is never shown the stored
  # secret, so it cannot send it back.
  defp instance_from(attrs) do
    stored = Settings.get()

    %{
      stored
      | smtp_host: take(attrs, "smtp_host", stored.smtp_host),
        smtp_port: take_integer(attrs, "smtp_port", stored.smtp_port),
        smtp_username: take(attrs, "smtp_username", stored.smtp_username),
        smtp_password: take(attrs, "smtp_password", stored.smtp_password),
        smtp_from_email: take(attrs, "smtp_from_email", stored.smtp_from_email),
        smtp_from_name: take(attrs, "smtp_from_name", stored.smtp_from_name),
        smtp_tls: take_tls(attrs, stored.smtp_tls)
    }
  end

  defp take(attrs, key, fallback) do
    case attrs[key] || attrs[String.to_existing_atom(key)] do
      value when is_binary(value) ->
        if String.trim(value) == "", do: fallback, else: String.trim(value)

      nil ->
        fallback

      value ->
        value
    end
  end

  defp take_integer(attrs, key, fallback) do
    case take(attrs, key, fallback) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {port, _} -> port
          :error -> fallback
        end

      _ ->
        fallback
    end
  end

  defp take_tls(attrs, fallback) do
    case take(attrs, "smtp_tls", fallback) do
      value when value in [:always, :never, :if_available] -> value
      value when value in ["always", "never", "if_available"] -> String.to_existing_atom(value)
      _ -> fallback || :if_available
    end
  end

  defp from_settings?, do: Application.get_env(:slipdock, :mailer_from_settings, true) != false

  defp printable(value) when is_binary(value), do: value
  defp printable(%{message: message}) when is_binary(message), do: message
  defp printable(value), do: inspect(value)
end
