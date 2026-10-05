defmodule SlipdockWeb.MCP.Plug do
  @moduledoc """
  `/mcp`: the board as an MCP server, over Streamable HTTP.

  The decisions behind it are on the wiki (W-21). In short:

    * **Stateless and JSON only.** No `Mcp-Session-Id`, never SSE. A POST
      carries one JSON-RPC message and gets one `application/json` answer;
      GET and DELETE get 405. A restart or a second node costs nothing.
    * **Revisions** 2025-11-25, 2025-06-18 and 2025-03-26 are spoken. Once a
      client has initialised it sends `MCP-Protocol-Version`; an unknown one
      is a 400, a missing one means 2025-03-26.
    * **Origin.** A browser's `Origin` that is not one of this server's own
      names is refused with 403 (DNS rebinding). Server-side clients such as
      claude.ai send none.
    * **Auth** is a bearer API token, looked up exactly as the API does. Not
      the `:api` pipeline, though: that refuses every POST from a read token,
      and here every call is a POST. Read/write is enforced per tool instead
      (`SlipdockWeb.MCP.Tools.call/3`). Without a token the 401 carries a
      `WWW-Authenticate` header naming the protected-resource metadata, which
      is how a client learns it has to sign in.

  This module is the transport and the JSON-RPC; the tools are in
  `SlipdockWeb.MCP.Tools`.
  """
  @behaviour Plug

  import Plug.Conn

  alias Slipdock.Accounts
  alias SlipdockWeb.MCP.Tools

  @versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  @latest hd(@versions)
  # What a client that sends no version header is taken to speak.
  @assumed "2025-03-26"
  # One JSON-RPC message. Nothing a tool accepts is anywhere near this.
  @max_body 1_000_000

  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602

  @doc "The protocol revisions this server speaks, newest first."
  def versions, do: @versions

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, conn} <- check_origin(conn),
         {:ok, conn} <- check_method(conn),
         {:ok, conn} <- authenticate(conn),
         {:ok, conn} <- check_version(conn),
         {:ok, message, conn} <- read_message(conn) do
      handle(conn, message)
    else
      {:halt, conn} -> halt(conn)
    end
  end

  ## Before the message ------------------------------------------------------

  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        {:ok, conn}

      [origin | _] ->
        if SlipdockWeb.Origin.known?(URI.parse(origin).host) do
          {:ok, conn}
        else
          {:halt, send_json(conn, 403, %{error: "forbidden: this Origin may not call /mcp"})}
        end
    end
  end

  defp check_method(%{method: "POST"} = conn), do: {:ok, conn}

  defp check_method(conn) do
    # GET would open a server-to-client stream, DELETE would end a session;
    # this server has neither.
    conn = put_resp_header(conn, "allow", "POST")
    {:halt, send_json(conn, 405, %{error: "method not allowed: /mcp takes POST only"})}
  end

  defp authenticate(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {%Accounts.User{} = user, api_token} <-
           Accounts.get_api_token(String.trim(token), ip: SlipdockWeb.ClientIP.from_conn(conn)) do
      {:ok, conn |> assign(:current_user, user) |> assign(:api_token, api_token)}
    else
      _ ->
        conn =
          put_resp_header(conn, "www-authenticate", challenge(conn))

        {:halt,
         send_json(conn, 401, %{
           error:
             "unauthorized: connect with OAuth, or pass an API token as " <>
               "`Authorization: Bearer <token>` (Account → API tokens)"
         })}
    end
  end

  @doc """
  The `WWW-Authenticate` value for a request without a usable token: where the
  protected-resource metadata is (RFC 9728), and the scope to ask for. Claude's
  clients start their sign-in from this.
  """
  def challenge(conn) do
    base = SlipdockWeb.BaseURL.from_conn(conn)

    ~s(Bearer resource_metadata="#{base}/.well-known/oauth-protected-resource/mcp", scope="write")
  end

  defp check_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        {:ok, assign(conn, :mcp_version, @assumed)}

      [version | _] when version in @versions ->
        {:ok, assign(conn, :mcp_version, version)}

      [version | _] ->
        {:halt,
         send_json(
           conn,
           400,
           error_body(
             nil,
             @invalid_request,
             "unsupported MCP-Protocol-Version #{inspect(version)}",
             %{supported: @versions}
           )
         )}
    end
  end

  defp read_message(conn) do
    case read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        decode(conn, body)

      {:more, _partial, conn} ->
        {:halt, send_json(conn, 413, error_body(nil, @invalid_request, "request too large"))}

      {:error, _} ->
        {:halt, send_json(conn, 400, error_body(nil, @parse_error, "could not read the body"))}
    end
  end

  defp decode(conn, body) do
    case Jason.decode(body) do
      {:ok, message} when is_map(message) ->
        {:ok, message, conn}

      {:ok, list} when is_list(list) ->
        # Batching went in 2025-06-18; one message per POST.
        {:halt,
         send_json(conn, 400, error_body(nil, @invalid_request, "batches are not supported"))}

      {:ok, _} ->
        {:halt,
         send_json(conn, 400, error_body(nil, @invalid_request, "expected a JSON-RPC object"))}

      {:error, _} ->
        {:halt, send_json(conn, 400, error_body(nil, @parse_error, "parse error: not JSON"))}
    end
  end

  ## The message -------------------------------------------------------------

  # A request: has a method and an id.
  defp handle(conn, %{"jsonrpc" => "2.0", "method" => method, "id" => id} = msg)
       when is_binary(method) and (is_binary(id) or is_integer(id)) do
    case dispatch(conn, method, Map.get(msg, "params") || %{}) do
      {:ok, result} -> send_json(conn, 200, %{jsonrpc: "2.0", id: id, result: result})
      {:error, code, message} -> send_json(conn, 200, error_body(id, code, message))
    end
  end

  # A notification (no id), or a response to a request we never send: accepted,
  # with nothing to say.
  defp handle(conn, %{"jsonrpc" => "2.0", "method" => method} = msg)
       when is_binary(method) and not is_map_key(msg, "id"),
       do: send_resp(conn, 202, "")

  defp handle(conn, %{"jsonrpc" => "2.0", "id" => _} = msg)
       when is_map_key(msg, "result") or is_map_key(msg, "error"),
       do: send_resp(conn, 202, "")

  defp handle(conn, msg) do
    id = if is_binary(msg["id"]) or is_integer(msg["id"]), do: msg["id"]
    send_json(conn, 400, error_body(id, @invalid_request, "not a JSON-RPC 2.0 request"))
  end

  defp dispatch(conn, "initialize", params) when is_map(params) do
    requested = params["protocolVersion"]

    {:ok,
     %{
       protocolVersion: if(requested in @versions, do: requested, else: @latest),
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{
         name: "slipdock",
         title: "Slipdock",
         version: to_string(Application.spec(:slipdock, :vsn))
       },
       instructions: instructions(conn)
     }}
  end

  defp dispatch(_conn, "ping", _params), do: {:ok, %{}}

  defp dispatch(_conn, "tools/list", _params),
    do: {:ok, %{tools: Enum.map(Tools.all(), &Tools.describe/1)}}

  defp dispatch(conn, "tools/call", %{"name" => name} = params) when is_binary(name) do
    case Tools.find(name) do
      nil ->
        {:error, @invalid_params, "unknown tool: #{name}"}

      tool ->
        context = %{
          user: conn.assigns.current_user,
          token: conn.assigns.api_token,
          base_url: SlipdockWeb.BaseURL.from_conn(conn)
        }

        {:ok, tool_result(Tools.call(tool, params["arguments"] || %{}, context))}
    end
  end

  defp dispatch(_conn, "tools/call", _params),
    do: {:error, @invalid_params, "tools/call needs a tool name"}

  defp dispatch(_conn, "initialize", _params),
    do: {:error, @invalid_params, "initialize params must be an object"}

  defp dispatch(_conn, method, _params),
    do: {:error, @method_not_found, "method not found: #{method}"}

  defp tool_result({:ok, data}) do
    %{content: [%{type: "text", text: Jason.encode!(data, pretty: true)}], isError: false}
    |> put_structured(data)
  end

  defp tool_result({:error, message}) do
    %{content: [%{type: "text", text: message}], isError: true}
  end

  # `structuredContent` must be an object; a tool answering a bare list says so
  # in the text alone.
  defp put_structured(result, data) when is_map(data),
    do: Map.put(result, :structuredContent, data)

  defp put_structured(result, _data), do: result

  # A pointer, not a copy: the guide is served in one place and changes there.
  defp instructions(conn) do
    "Slipdock is a kanban board with a wiki. Top-level cards are epics and the work " <>
      "is in their subcards; take work from the top of the ready list, move a card " <>
      "to the doing list when you start it, comment as you go, and mark it complete " <>
      "and move it to the done list when it is finished. Read the full conventions " <>
      "with the get_guide tool, or at #{SlipdockWeb.BaseURL.from_conn(conn)}/api/guide."
  end

  ## Answers -----------------------------------------------------------------

  defp error_body(id, code, message, data \\ nil) do
    error = %{code: code, message: message}
    error = if data, do: Map.put(error, :data, data), else: error
    %{jsonrpc: "2.0", id: id, error: error}
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
