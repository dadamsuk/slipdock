defmodule SlipdockWeb.MCPResult do
  @moduledoc """
  What an MCP tool answered, decoded. A tool's answer is its JSON as the
  result's one text block (#3176): the server sends no `structuredContent`,
  so a test reads what a client's model reads.
  """

  @doc "The data in a `tools/call` result (the JSON-RPC `result` member)."
  def mcp_data(%{"content" => [%{"type" => "text", "text" => text} | _]}),
    do: Jason.decode!(text)
end
