defmodule Slipdock.Automations.Notifier do
  @moduledoc """
  The outside world, as automations see it: email and callbacks.

  Both are slow and neither should hold up the card the user just dragged,
  so by default they run under `Slipdock.TaskSupervisor` and report `:ok`
  straight away. Set `config :slipdock, :automations, async: false` (as the
  test environment does) to send inline and get the real result back.
  """

  require Logger

  import Swoosh.Email

  alias Slipdock.Egress
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

  @doc """
  Calls `url` with `payload`. A `GET` carries it in the query string (nested
  keys flattened to `card.title=…`); every other method sends it as a JSON
  body. `method` is anything in `get`, `post`, `put`, `patch`, in any case —
  anything else is a POST.

  `log`, when given, is what the call is recorded against once it has
  finished — `board_id`, `rule_id`, `rule_name`, `card_id`, `card_title` —
  so the board's owner can see it went (see `Slipdock.Automations.Callback`).
  A URL that is never called is recorded too: it is still a callback that
  did not arrive.

  Every call goes through `Slipdock.Egress`: no private or loopback
  addresses, no redirects. What comes back — and what the log shows — is
  the HTTP status or a broad outcome ("unreachable", "timed out"), never the
  transport's own error, so the log cannot be read as a port scan.
  """
  def call(url, payload, method \\ nil, log \\ nil) do
    method = method(method)

    case Egress.prepare(url) do
      {:ok, pinned, options} ->
        run(fn ->
          pinned |> timed_callback(payload, method, options) |> record(log, url, method)
        end)

      {:error, reason} ->
        record({{:error, "#{url} #{reason}"}, nil, nil}, log, url, method)
    end
  end

  @doc "The HTTP method a callback will actually use, given what the rule asked for."
  def method(wanted) do
    case wanted |> to_string() |> String.downcase() do
      "get" -> :get
      "put" -> :put
      "patch" -> :patch
      _ -> :post
    end
  end

  @doc """
  A nested payload as flat, sorted query parameters: `%{card: %{title: "x"}}`
  becomes `[{"card.title", "x"}]`. Lists are joined with commas and nils are
  left out, because a query string has no way to say either.
  """
  def query(payload), do: payload |> flatten("") |> Enum.sort()

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

  defp timed_callback(url, payload, method, options) do
    started = System.monotonic_time(:millisecond)
    {result, status} = send_callback(url, payload, method, options)
    {result, status, System.monotonic_time(:millisecond) - started}
  end

  # The result goes back to the caller as it came; the log is a side note,
  # and a log that cannot be written must not turn a delivered call into a
  # failed one.
  defp record({result, status, duration}, log, url, method) do
    if is_map(log) do
      error =
        case result do
          :ok -> nil
          {:error, reason} -> reason
        end

      try do
        Slipdock.Automations.log_callback(
          Map.merge(log, %{
            method: method |> to_string() |> String.upcase(),
            url: url,
            status: status,
            error: error,
            duration_ms: duration
          })
        )
      rescue
        exception -> Logger.warning("Could not log a callback: #{Exception.message(exception)}")
      end
    end

    result
  end

  defp send_callback(url, payload, :get, options),
    do: request([url: url, method: :get, params: query(payload)] ++ options)

  defp send_callback(url, payload, method, options),
    do: request([url: url, method: method, json: payload] ++ options)

  defp request(options) do
    options =
      [retry: false, receive_timeout: 15_000]
      |> Keyword.merge(options)
      |> Keyword.merge(Application.get_env(:slipdock, :automations, [])[:req_options] || [])

    case Req.request(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, status}

      {:ok, %Req.Response{status: status}} when status in 300..399 ->
        {{:error, "HTTP 3xx (redirects are not followed)"}, status}

      {:ok, %Req.Response{status: status}} ->
        {{:error, "HTTP #{status}"}, status}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {{:error, "timed out"}, nil}

      {:error, exception} ->
        Logger.info("Callback to #{options[:url]} failed: #{Exception.message(exception)}")
        {{:error, "unreachable"}, nil}
    end
  end

  ## Flattening --------------------------------------------------------------

  defp flatten(%{} = map, prefix) when not is_struct(map) do
    Enum.flat_map(map, fn {key, value} -> flatten(value, join(prefix, key)) end)
  end

  defp flatten(nil, _prefix), do: []

  defp flatten(list, prefix) when is_list(list),
    do: [{prefix, Enum.map_join(list, ",", &scalar/1)}]

  defp flatten(value, prefix), do: [{prefix, scalar(value)}]

  defp join("", key), do: to_string(key)
  defp join(prefix, key), do: "#{prefix}.#{key}"

  defp scalar(%Date{} = date), do: Date.to_iso8601(date)
  defp scalar(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value), do: to_string(value)

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

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
