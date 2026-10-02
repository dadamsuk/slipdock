defmodule Slipdock.Automations.Notifier do
  @moduledoc """
  The outside world, as automations see it: email and webhooks.

  Both are slow and neither should hold up the card the user just dragged,
  so by default they run under `Slipdock.TaskSupervisor` and report `:ok`
  straight away. Set `config :slipdock, :automations, async: false` (as the
  test environment does) to send inline and get the real result back.
  """

  require Logger

  import Swoosh.Email

  alias Slipdock.Mailer

  @doc "Sends one plain-text email to every address in `to`."
  def deliver([], _subject, _body), do: {:error, "no recipient"}

  def deliver(to, subject, body) when is_list(to) do
    case Enum.filter(to, &valid_email?/1) do
      [] ->
        {:error, "no valid recipient in #{Enum.join(to, ", ")}"}

      recipients ->
        run(fn -> send_mail(recipients, subject, body) end)
    end
  end

  @doc "POSTs `payload` as JSON to `url`."
  def post(url, payload, method \\ nil) do
    if valid_url?(url) do
      run(fn -> send_webhook(url, payload, method) end)
    else
      {:error, "#{url} is not an http(s) URL"}
    end
  end

  ## Delivery -----------------------------------------------------------------

  defp send_mail(recipients, subject, body) do
    email =
      new()
      |> to(recipients)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver_configured(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Automation email to #{Enum.join(recipients, ", ")} failed: #{inspect(reason)}"
        )

        {:error, describe(reason)}
    end
  end

  defp send_webhook(url, payload, method) do
    method =
      if to_string(method) in ~w(put patch), do: String.to_existing_atom(method), else: :post

    case Req.request(
           url: url,
           method: method,
           json: payload,
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # Async delivery can't report a failure to the caller, so it logs instead.
  defp run(fun) do
    if async?() do
      Task.Supervisor.start_child(Slipdock.TaskSupervisor, fn ->
        case fun.() do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Automation delivery failed: #{reason}")
        end
      end)

      :ok
    else
      fun.()
    end
  end

  defp async?, do: Application.get_env(:slipdock, :automations, [])[:async] != false

  defp valid_email?(address) when is_binary(address),
    do: address =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  defp valid_email?(_), do: false

  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
