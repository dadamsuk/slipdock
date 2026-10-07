defmodule SlipdockWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets a Content-Security-Policy on every browser response: defence in depth
  behind the wiki's HTML sanitiser, so that a hole in it is not also a way to
  run script in this app's origin.

  What the directives are for, since a CSP that nobody understands gets
  loosened at the first broken page:

    * `script-src 'self'` — every line of JavaScript here is a file from this
      origin (`app.js` and `theme.js`). There is deliberately no inline script
      and so no need for a nonce; if you add one, give it a nonce rather than
      allowing `'unsafe-inline'`, which would undo most of this.
    * `style-src 'self' 'unsafe-inline'` — Tailwind is a stylesheet, but
      components and wiki content carry `style` attributes, which this allows.
      Inline style cannot run script, so the cost is small.
    * `img-src` and `media-src` include `https:` because wiki pages and card
      descriptions may point at pictures elsewhere, and `data:`/`blob:` because
      previews of a file being uploaded are made in the browser.
    * `connect-src 'self'` covers the LiveView WebSocket, which is same-origin.
    * `frame-ancestors 'self'` rather than `'none'`: other sites cannot frame
      this one, but development's live-reload frame is same-origin and would
      otherwise break.
    * `object-src 'none'`, `base-uri 'self'`, `form-action 'self'` close the
      old tricks — plugins, a rewritten base URL, a form posted elsewhere.

  Override the whole header with `config :slipdock, :csp, "…"`, or set it to
  `false` to send none of this — which leaves the two directives Phoenix's own
  `put_secure_browser_headers` sets, and is what you want if a proxy in front
  is setting the real policy.
  """

  @behaviour Plug

  @default [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https:",
    "media-src 'self' data: blob: https:",
    "font-src 'self' data:",
    "connect-src 'self'",
    "frame-ancestors 'self'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'"
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Slipdock.Config.get(:csp, :default) do
      false ->
        conn

      :default ->
        Plug.Conn.put_resp_header(conn, "content-security-policy", Enum.join(@default, "; "))

      policy when is_binary(policy) ->
        Plug.Conn.put_resp_header(conn, "content-security-policy", policy)
    end
  end

  @doc """
  Lets the page being sent submit a form that ends up at `origin` as well as
  here. Chrome applies `form-action` to where a form's response redirects,
  not only to where it posts, so the OAuth consent page — which posts here and
  is answered with a redirect to the app that asked — needs the app's origin
  named. Only that page, and only that origin.
  """
  def allow_form_action(conn, origin) when is_binary(origin) do
    case Plug.Conn.get_resp_header(conn, "content-security-policy") do
      [policy] ->
        widened = String.replace(policy, "form-action 'self'", "form-action 'self' #{origin}")
        Plug.Conn.put_resp_header(conn, "content-security-policy", widened)

      _ ->
        conn
    end
  end

  @doc "The policy this plug sends, for tests and for printing in the docs."
  def policy, do: Enum.join(@default, "; ")
end
