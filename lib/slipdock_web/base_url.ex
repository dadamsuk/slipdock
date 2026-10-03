defmodule SlipdockWeb.BaseURL do
  @moduledoc """
  The address to hand an agent: the URL this server is actually reachable at,
  from the point of view of whoever is asking.

  It exists because `conn.scheme` is the scheme of the *last hop*. Behind a TLS
  proxy — which is every hosted install — that hop is plain http, so a guide
  built from it tells every agent to talk to `http://…`: either a redirect to
  follow or, worse, a token sent in clear. The configured `:url` (from
  `PHX_HOST` and `SLIPDOCK_URL_SCHEME`) knows better, and is what the app
  already uses for the links it emails.

  So: when the caller reached us by the name this server knows itself by, that
  configuration wins. When they reached us by some other name — a tailnet IP on
  :4000, a LAN hostname, the way a self-hosted install is usually used — keep
  the name they used, because it is the one that works for them, and take the
  scheme from the proxy's `x-forwarded-proto` if there is one.
  """

  @doc "The base URL for a plain request, with no trailing slash."
  def from_conn(conn) do
    if canonical_host?(conn.host) do
      SlipdockWeb.Endpoint.url()
    else
      case forwarded_scheme(conn) do
        # The proxy terminated the TLS, so the port we were reached on is the
        # proxy's own hop — :80, usually — and nothing the caller should be
        # told to connect to. Theirs is whatever is standard for https.
        "https" -> build("https", conn.host, if(conn.port == 80, do: 443, else: conn.port))
        _ -> build(to_string(conn.scheme), conn.host, conn.port)
      end
    end
  end

  @doc """
  The same, for a LiveView, which has the browser's URL as `socket.host_uri`
  rather than a `conn`.
  """
  def from_socket(%{host_uri: %URI{} = uri}) do
    if canonical_host?(uri.host) do
      SlipdockWeb.Endpoint.url()
    else
      build(uri.scheme || "http", uri.host, uri.port)
    end
  end

  def from_socket(_socket), do: SlipdockWeb.Endpoint.url()

  defp canonical_host?(host),
    do: not is_nil(host) and host == SlipdockWeb.Endpoint.config(:url)[:host]

  defp build(scheme, host, port) do
    port = if default_port?(scheme, port), do: "", else: ":#{port}"
    "#{scheme}://#{host}#{port}"
  end

  defp default_port?("https", port), do: port in [443, nil]
  defp default_port?(_scheme, port), do: port in [80, nil]

  # Only ever an upgrade: a proxy saying "this arrived over TLS" is worth
  # believing because the alternative is handing out an http URL that leaks the
  # token. A header claiming the reverse is not worth believing at all.
  defp forwarded_scheme(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-proto") do
      [value | _] -> if String.downcase(String.trim(value)) == "https", do: "https"
      [] -> nil
    end
  end
end
