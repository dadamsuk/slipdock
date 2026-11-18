defmodule SlipdockWeb.MCPResult do
  @moduledoc """
  What an MCP tool answered, decoded. A tool's answer is its JSON as the
  result's one text block (#3176): the server sends no `structuredContent`,
  so a test reads what a client's model reads.
  """

  @doc "The data in a `tools/call` result (the JSON-RPC `result` member)."
  def mcp_data(%{"content" => [%{"type" => "text", "text" => text} | _]}),
    do: Jason.decode!(text)

  @doc """
  Calls an MCP tool on `conn` as a client would: `{false, data}` for an
  answer, `{true, text}` for a refusal (`isError`). What the operations'
  tests (`test/slipdock_web/ops/`) set beside REST's answer to the same call.
  """
  def call_mcp_tool(conn, tool, args) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })

    result =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(SlipdockWeb.Endpoint, :post, "/mcp", body)
      |> Phoenix.ConnTest.json_response(200)
      |> Map.fetch!("result")

    case result do
      %{"isError" => true, "content" => [%{"text" => text}]} -> {true, text}
      _ -> {false, mcp_data(result)}
    end
  end
end
