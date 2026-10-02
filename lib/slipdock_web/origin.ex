defmodule SlipdockWeb.Origin do
  @moduledoc """
  Which origins may open a live-update socket, and — the point of this module —
  saying something useful when one may not.

  Phoenix's own refusal is correct and unhelpful here: it tells you to edit
  `config/` files and pass `check_origin:` when configuring your endpoint, and
  somebody running the published container has neither. The symptom is also
  quiet. The page loads, the socket is refused, LiveView retries, and nothing
  in the browser says why — the only sign is a wall of Phoenix's text in
  `docker compose logs`.

  So this does what `check_origin: true` does (compare the **host**, not the
  scheme or port) against `PHX_HOST` plus anything in `SLIPDOCK_CHECK_ORIGIN`,
  and on a refusal logs one line naming the variable to set and the value to
  set it to.
  """
  require Logger

  @behaviour Plug

  @doc """
  Plug: notices when a page is served to a name this server does not know
  itself by, and says so once.

  The socket check below only fires when LiveView connects, which is already
  one symptom deep. This fires on the first page load, which is the thing
  somebody definitely does — so a misconfiguration announces itself whatever
  caused it: the wrong file, a typo, or `docker compose restart`, which does
  not re-read `.env` (only `up -d` does).

  It never refuses anything. Being reached by an unexpected name is a
  configuration problem, not an attack, and a server that stopped answering
  would be a worse version of the same confusion.
  """
  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case hosts() do
      # Not configured: development and test, where this does not apply.
      [] -> conn
      allowed -> check_host(conn, allowed)
    end
  end

  defp check_host(conn, allowed) do
    host = conn.host

    unless loopback?(host) or Enum.any?(allowed, &match_host?(host, &1)) do
      complain(host, allowed)
    end

    conn
  end

  # Health checks and probes arrive this way — the container's own HEALTHCHECK
  # curls 127.0.0.1 — and nobody reaches a server "at" loopback from outside.
  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

  @doc """
  Whether a socket connection from `origin` is allowed.

  Host-only comparison, deliberately matching what Phoenix does for
  `check_origin: true`: the port and scheme a browser arrived on are not worth
  refusing over when the hostname is one we recognise, and insisting on them
  turns every reverse proxy into a support question.
  """
  @spec allowed?(URI.t()) :: boolean()
  def allowed?(%URI{host: nil}), do: false

  def allowed?(%URI{host: host}) do
    allowed = hosts()

    if Enum.any?(allowed, &match_host?(host, &1)) do
      true
    else
      complain(host, allowed)
      false
    end
  end

  def allowed?(_), do: false

  @doc "The hostnames this server will accept a socket from."
  def hosts do
    # `|| []` rather than a default argument: a key that is present and nil is
    # not an absent key, and `get_env/3`'s default does not cover it.
    Application.get_env(:slipdock, :origin_hosts) || []
  end

  @doc """
  Turns the entries of `SLIPDOCK_CHECK_ORIGIN` into bare hostnames.

  People write these every way there is — `example.com`, `//example.com`,
  `https://example.com:8443` — because that is what Phoenix's own
  documentation shows. All of them mean the same thing here.
  """
  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&to_host/1)
    |> Enum.reject(&is_nil/1)
  end

  defp to_host(entry) do
    case URI.parse(entry) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      # A bare hostname parses as a path, not a host.
      %URI{path: path} when is_binary(path) and path != "" -> String.trim(path, "/")
      _ -> nil
    end
  end

  # Mirrors Phoenix's own wildcard handling, so that `*.example.com` keeps
  # meaning what it means everywhere else.
  defp match_host?(host, "*." <> suffix), do: String.ends_with?(host, suffix)
  defp match_host?(host, allowed), do: String.downcase(host) == String.downcase(allowed)

  # Once per name per boot. A refused socket retries, and a reconnect loop would
  # otherwise bury the one line worth reading under copies of itself.
  defp complain(host, allowed) do
    if remember(host) do
      Logger.error("""

      ┌─ This server is being reached at a name it does not know itself by ─┐

        Reached at:   #{host}
        Configured:   #{Enum.join(allowed, ", ")}

        Two things are wrong until that matches. Pages opened at #{host} will
        load and then never update, and the sign-in links it emails will point
        at #{List.first(allowed)}, where nobody is.

        Fix it in the .env beside compose.yaml:

            PHX_HOST=#{host}

        ...then `docker compose up -d`. Not `restart` — that reuses the
        container and never re-reads .env, which is the usual reason this
        message is still here after somebody thought they had fixed it.

        Reached by several names? Keep the main one in PHX_HOST and list the
        rest: SLIPDOCK_CHECK_ORIGIN=#{host},another.example

      └─────────────────────────────────────────────────────────────────────┘
      """)
    end
  end

  @remembered {__MODULE__, :complained}
  # Enough to cover a server with a handful of names, and bounded so that a
  # stream of forged Origin headers cannot grow this without limit.
  @remember_limit 20

  defp remember(host) do
    seen = :persistent_term.get(@remembered, MapSet.new())

    cond do
      MapSet.member?(seen, host) -> false
      MapSet.size(seen) >= @remember_limit -> false
      true -> :persistent_term.put(@remembered, MapSet.put(seen, host)) == :ok
    end
  end
end
