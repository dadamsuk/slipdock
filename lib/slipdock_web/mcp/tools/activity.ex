defmodule SlipdockWeb.MCP.Tools.Activity do
  @moduledoc """
  A board's activity log, or with `view: "ledger"` its ledger (#1948). Made
  from `SlipdockWeb.Ops.Activity`.
  """
  use SlipdockWeb.Ops.MCPTool, op: SlipdockWeb.Ops.Activity
end
