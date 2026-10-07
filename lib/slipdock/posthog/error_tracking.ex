defmodule Slipdock.Posthog.ErrorTracking do
  @moduledoc """
  The server's errors, in PostHog's Error Tracking — only once an admin has
  filled in a PostHog project key and host (`Slipdock.Settings.posthog/0`).
  With none, nothing is sent anywhere, the same as the browser analytics.

  Two halves:

    * an Erlang `:logger` handler (`log/2`), attached at boot, which sees every
      log event at `:error` and above — a `Logger.error/1`, a crashed process,
      an exception raised in a request — and hands it on. It runs in the
      process that logged, so it does nothing there but a cast;

    * this GenServer, which reads the settings and posts each one to PostHog's
      capture endpoint as an `$exception` event: the exception's type and
      message and its stack trace when there is one, the log message
      otherwise.

  Logging must never be held up or broken by this, and this must never feed
  itself, so:

    * events this process logs are ignored (a failed post is logged at `:info`
      in any case, below the handler's level);
    * when the mailbox is already long, events are dropped rather than queued;
    * at most 30 events a minute are sent, so a crash loop does not flood
      the project — the rest are counted and dropped;
    * a post that fails is dropped, not retried.

  The browser's own errors reach PostHog by posthog-js's exception autocapture
  (`capture_exceptions` in `assets/js/posthog.js`).
  """

  use GenServer

  require Logger

  @handler_id :slipdock_posthog_errors
  @max_queue 100
  @max_per_minute 30
  @max_message 4_000

  ## The logger handler ----------------------------------------------------

  @doc """
  Attaches the `:logger` handler, pointing at the server `target` (this
  module's registered name unless a test says otherwise).
  """
  def attach(id \\ @handler_id, target \\ __MODULE__) do
    case :logger.add_handler(id, __MODULE__, %{level: :error, config: %{target: target}}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      other -> other
    end
  end

  @doc "Detaches the handler `attach/2` added."
  def detach(id \\ @handler_id), do: :logger.remove_handler(id)

  @doc false
  # `:logger` calls this in the process that logged, for every event at the
  # handler's level or above. It must be cheap and must not raise.
  def log(event, %{config: %{target: target}}) do
    with pid when is_pid(pid) <- GenServer.whereis(target),
         true <- pid != self(),
         {:message_queue_len, waiting} when waiting < @max_queue <-
           Process.info(pid, :message_queue_len) do
      GenServer.cast(pid, {:report, event})
    end

    :ok
  end

  ## The reporter ----------------------------------------------------------

  @doc """
  Starts the reporter. Options, for tests: `:name`, and `:settings` — a
  zero-arity function standing in for `Slipdock.Settings.posthog/0`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    settings = Keyword.get(opts, :settings, &Slipdock.Settings.posthog/0)
    {:ok, %{settings: settings, window: nil, sent: 0, dropped: 0}}
  end

  @impl true
  def handle_cast({:report, event}, state) do
    case configured(state.settings) do
      nil -> {:noreply, state}
      posthog -> {:noreply, maybe_send(posthog, event, state)}
    end
  end

  # Settings can fail to load — the Repo not up yet, or the very error being
  # reported being the database's — and a reporter that crashed on it would
  # only log another error.
  defp configured(settings) do
    settings.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp maybe_send(posthog, event, state) do
    minute = System.monotonic_time(:second) |> div(60)
    state = if state.window == minute, do: state, else: roll_window(state, minute)

    if state.sent < @max_per_minute do
      send_event(posthog, event)
      %{state | sent: state.sent + 1}
    else
      %{state | dropped: state.dropped + 1}
    end
  end

  defp roll_window(%{dropped: 0} = state, minute), do: %{state | window: minute, sent: 0}

  defp roll_window(state, minute) do
    Logger.info("PostHog error tracking: dropped #{state.dropped} errors over the rate limit")
    %{state | window: minute, sent: 0, dropped: 0}
  end

  defp send_event(posthog, event) do
    options =
      [
        url: posthog.host <> "/i/v0/e/",
        method: :post,
        json: payload(posthog.key, event),
        retry: false,
        receive_timeout: 10_000
      ] ++ (Slipdock.Config.get(:posthog, [])[:req_options] || [])

    case Req.request(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.info("PostHog error tracking: capture answered HTTP #{status}")

      {:error, exception} ->
        Logger.info("PostHog error tracking: capture failed: #{Exception.message(exception)}")
    end
  rescue
    exception ->
      Logger.info("PostHog error tracking: capture failed: #{Exception.message(exception)}")
  end

  ## The event -------------------------------------------------------------

  @doc """
  The body posted to PostHog's capture endpoint for a `:logger` event: an
  `$exception` with one entry in `$exception_list`. No person profile is made
  for it — it is the server's, not a visitor's.
  """
  def payload(api_key, %{level: level, meta: meta} = event) do
    {type, value, frames} = exception(event)

    properties =
      %{
        "$exception_list" => [
          %{
            "type" => type,
            "value" => value,
            "mechanism" => %{"handled" => frames == [], "type" => "generic"},
            "stacktrace" => %{"type" => "raw", "frames" => frames}
          }
        ],
        "$exception_level" => to_string(level),
        "$lib" => "slipdock",
        "$process_person_profile" => false,
        "node" => to_string(node())
      }
      |> put_present("request_id", meta[:request_id])
      |> put_present("source", source(meta[:mfa]))

    %{
      "api_key" => api_key,
      "event" => "$exception",
      "distinct_id" => "slipdock-server",
      "timestamp" => timestamp(meta[:time]),
      "properties" => properties
    }
  end

  # A crash carries `{reason, stacktrace}` in `crash_reason`: an exception, or
  # an exit/throw. Anything else is a plain `Logger.error`, reported by its
  # message.
  defp exception(%{meta: %{crash_reason: {reason, stacktrace}}} = event)
       when is_list(stacktrace) do
    if is_exception(reason) do
      {inspect(reason.__struct__), safe_message(reason), frames(stacktrace)}
    else
      {"exit", truncate(inspect(reason)) <> context(event), frames(stacktrace)}
    end
  end

  defp exception(%{level: level} = event), do: {"Logger.#{level}", message(event), []}

  defp context(event) do
    case message(event) do
      "" -> ""
      message -> "\n\n" <> message
    end
  end

  defp safe_message(exception) do
    truncate(Exception.message(exception))
  rescue
    _ -> inspect(exception.__struct__)
  end

  # The log line as the console would print it — `:logger_formatter` knows
  # every shape `msg` can take, report callbacks included.
  defp message(event) do
    event
    |> :logger_formatter.format(%{single_line: false, template: [:msg]})
    |> IO.chardata_to_string()
    |> String.trim()
    |> truncate()
  rescue
    _ -> ""
  end

  defp truncate(text) when byte_size(text) > @max_message,
    do: binary_part(text, 0, @max_message) <> "…"

  defp truncate(text), do: text

  # PostHog lists frames oldest call first, the raising call last.
  defp frames(stacktrace) do
    stacktrace
    |> Enum.map(&frame/1)
    |> Enum.reverse()
  end

  defp frame({module, function, arity_or_args, location}) do
    arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args

    %{
      "platform" => "custom",
      "lang" => "elixir",
      "function" => Exception.format_mfa(module, function, arity),
      "module" => inspect(module),
      "filename" => location |> Keyword.get(:file, ~c"") |> to_string(),
      "lineno" => Keyword.get(location, :line),
      "in_app" => :application.get_application(module) == {:ok, :slipdock},
      "resolved" => true
    }
  end

  defp frame(other),
    do: %{"platform" => "custom", "lang" => "elixir", "function" => inspect(other)}

  defp source({module, function, arity}), do: Exception.format_mfa(module, function, arity)
  defp source(_), do: nil

  defp timestamp(microseconds) when is_integer(microseconds),
    do: microseconds |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, to_string(value))
end
