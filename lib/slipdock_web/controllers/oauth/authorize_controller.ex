defmodule SlipdockWeb.OAuth.AuthorizeController do
  @moduledoc """
  `/oauth/authorize` — where a person decides whether a third-party app may
  act on their account.

  The same two rules as `/activate` (`SlipdockWeb.DeviceActivationController`):

  **The decision is a POST with CSRF, never a GET.** The GET only shows the
  question, so a link cannot approve itself when opened.

  **Approving blind is approving anything.** The page names the app, what it
  would be allowed to do, and — because the name is whatever the app chose to
  call itself — the address its approval is sent back to.

  A request naming an unknown client or an unregistered redirect URI is
  answered here and never redirected anywhere (RFC 6749 §4.1.2.1). Every other
  problem, and a refusal, goes back to the app as an `error`.
  """
  use SlipdockWeb, :controller

  alias Slipdock.OAuth
  alias SlipdockWeb.Plugs.ContentSecurityPolicy

  @request_fields ~w(response_type client_id redirect_uri state code_challenge
                     code_challenge_method scope resource)

  def show(conn, params) do
    with {:ok, request} <- validate(conn, params) do
      conn
      |> ContentSecurityPolicy.allow_form_action(origin(request.redirect_uri))
      |> render(:show,
        request: request,
        fields: Map.take(params, @request_fields),
        page_title: "Connect an app"
      )
    end
  end

  def decide(conn, params) do
    with {:ok, request} <- validate(conn, params) do
      case params["decision"] do
        "approve" ->
          code = OAuth.issue_code(conn.assigns.current_user, request, params["granted_scope"])
          back(conn, request.redirect_uri, request.state, code: code)

        _ ->
          back(conn, request.redirect_uri, request.state,
            error: "access_denied",
            error_description: "the person refused"
          )
      end
    end
  end

  defp validate(conn, params) do
    case OAuth.validate_authorization(params, SlipdockWeb.BaseURL.from_conn(conn)) do
      {:ok, request} ->
        {:ok, request}

      {:error, {:redirect, redirect_uri, error, description}} ->
        back(conn, redirect_uri, params["state"], error: error, error_description: description)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> render(:error, reason: reason, page_title: "Connect an app")
    end
  end

  # Back to the app, with `iss` so it can tell which server answered
  # (RFC 9207) and `state` returned as it came.
  defp back(conn, redirect_uri, state, query) do
    query = query ++ [iss: SlipdockWeb.BaseURL.from_conn(conn)]
    query = if state, do: query ++ [state: state], else: query

    uri = redirect_uri |> URI.parse() |> URI.append_query(URI.encode_query(query))
    redirect(conn, external: URI.to_string(uri))
  end

  defp origin(uri) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(uri)
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    if port == URI.default_port(scheme),
      do: "#{scheme}://#{host}",
      else: "#{scheme}://#{host}:#{port}"
  end
end
