defmodule SlipdockWeb.MCP.Tools.DeleteBoard do
  @moduledoc "Deletes a board for good, once confirmed. Made from `SlipdockWeb.Ops.DeleteBoard`."
  use SlipdockWeb.Ops.MCPTool, op: SlipdockWeb.Ops.DeleteBoard
end
