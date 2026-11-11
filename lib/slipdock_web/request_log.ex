defmodule SlipdockWeb.RequestLog do
  @moduledoc """
  The request log: a line when a request comes in (`GET /boards/3`) and one
  when its answer goes out (`Sent 200 in 4ms`), as Phoenix's own
  `Phoenix.Logger` writes them, in its place (`Plug.Telemetry` in
  `SlipdockWeb.Endpoint` has `log: false`).

  The difference is the path: a route whose path segment is itself the
  credential has that segment written as `[FILTERED]`, as
  `:filter_parameters` does for parameters, so the log never holds a value
  that opens something.
  """

  require Logger

  @handler_id {__MODULE__, :endpoint}

  # The first path segment of each route whose next segment is a credential.
  # `/login/passkey` and `/login/passkey/options` are the sign-in page's own.
  @filtered_after ~w(login p w)
  @filtered_after_api ~w(upload download)
  @not_secret ~w(passkey)

  @doc "Attaches the log to the endpoint's telemetry events."
  def attach do
    :telemetry.attach_many(
      @handler_id,
      [[:phoenix, :endpoint, :start], [:phoenix, :endpoint, :stop]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event([:phoenix, :endpoint, :start], _measurements, %{conn: conn}, _config) do
    Logger.info(fn -> [conn.method, ?\s, path(conn)] end)
  end

  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    Logger.info(fn ->
      type = if conn.state == :set_chunked, do: "Chunked", else: "Sent"
      status = conn.status |> Plug.Conn.Status.code() |> Integer.to_string()
      [type, ?\s, status, " in ", Phoenix.Logger.duration(duration)]
    end)
  end

  @doc """
  The path as the log writes it: the request path as it came, unless a
  segment of it is a credential, which is then written as `[FILTERED]`.

      iex> SlipdockWeb.RequestLog.path(%{request_path: "/p/abc123", path_info: ["p", "abc123"]})
      "/p/[FILTERED]"
      iex> SlipdockWeb.RequestLog.path(%{request_path: "/boards/3", path_info: ["boards", "3"]})
      "/boards/3"
  """
  def path(%{request_path: request_path, path_info: path_info}) do
    case redact(path_info) do
      ^path_info -> request_path
      redacted -> "/" <> Enum.join(redacted, "/")
    end
  end

  defp redact([first, secret | rest]) when first in @filtered_after and secret not in @not_secret,
    do: [first, "[FILTERED]" | rest]

  defp redact(["api", first, _secret | rest]) when first in @filtered_after_api,
    do: ["api", first, "[FILTERED]" | rest]

  defp redact(path_info), do: path_info
end
