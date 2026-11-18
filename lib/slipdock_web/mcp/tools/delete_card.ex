defmodule SlipdockWeb.MCP.Tools.DeleteCard do
  @moduledoc "Deletes a card for good, once confirmed. Made from `SlipdockWeb.Ops.DeleteCard`."
  use SlipdockWeb.Ops.MCPTool, op: SlipdockWeb.Ops.DeleteCard
end
