defmodule SlipdockWeb.MCP.Tools.GardenDecide do
  @moduledoc """
  Applies, dismisses or undoes one gardener suggestion (W-1807), once the
  person has approved it. Made from `SlipdockWeb.Ops.GardenDecide`.
  """
  use SlipdockWeb.Ops.MCPTool, op: SlipdockWeb.Ops.GardenDecide
end
