defmodule SlipdockWeb.Ops.MCPCall do
  @moduledoc """
  What an MCP tool made from a definition (`SlipdockWeb.Ops.MCPTool`) does
  on a call: cast the arguments, ask `confirm/2` first when the definition
  has a `confirm` (refusing, with nothing done, until the caller confirms),
  run it, and word a refusal as REST's (`forbidden: …` for a 403 too).
  """

  alias SlipdockWeb.MCP.Args

  @doc "Whether the operation can't be undone: MCP's `destructiveHint`."
  def destructive?(op), do: Map.get(op.definition(), :destructive?, false)

  @doc "The tool's `call/2`, given the MCP context's `auth` map."
  def call(op, args, auth) do
    with {:ok, params} <- refusal(SlipdockWeb.Ops.cast(op, args, :mcp)),
         :ok <- refusal(confirmed(op, params, auth)) do
      refusal(op.run(params, auth))
    end
  end

  defp confirmed(op, params, auth) do
    if op.definition()[:confirm], do: op.confirm(params, auth), else: :ok
  end

  # As `FallbackController` words it, so REST and MCP refuse alike.
  defp refusal({:error, :forbidden, message}) when is_binary(message),
    do: {:error, "forbidden: " <> message}

  defp refusal(result), do: Args.refusal(result)
end
