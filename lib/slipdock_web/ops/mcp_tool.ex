defmodule SlipdockWeb.Ops.MCPTool do
  @moduledoc """
  An MCP tool made from an operation's definition.
  `use SlipdockWeb.Ops.MCPTool, op: SlipdockWeb.Ops.MoveCard` is the whole tool.

  A refusal reads as REST's does (`forbidden: …` for a 403 too).

  A definition with `confirm` (see `SlipdockWeb.Ops.Op`) is asked
  `confirm/2` before it runs: the tool refuses, and does nothing, until the
  caller confirms.
  """

  defmacro __using__(op: op) do
    quote do
      @behaviour SlipdockWeb.MCP.Tool
      @op unquote(op)

      @doc "The definition this tool is made from (`OpsCheckTest` reads it)."
      def __op__, do: @op

      @impl true
      def name, do: @op.definition().name
      @impl true
      def title, do: @op.definition().title
      @impl true
      def description, do: @op.definition().summary
      @impl true
      def input_schema, do: SlipdockWeb.Ops.input_schema(@op)
      @impl true
      def read_only?, do: not @op.definition().writes?
      @impl true
      def destructive?, do: SlipdockWeb.Ops.MCPTool.destructive?(@op)

      @impl true
      def call(args, context) do
        SlipdockWeb.Ops.MCPTool.call(@op, args, SlipdockWeb.MCP.Args.auth(context))
      end
    end
  end

  alias SlipdockWeb.MCP.Args

  @doc false
  def destructive?(op), do: Map.get(op.definition(), :destructive?, false)

  @doc false
  def call(op, args, auth) do
    with {:ok, params} <- refusal(SlipdockWeb.Ops.cast(op, args, :mcp)),
         :ok <- refusal(confirmed(op, params, auth)) do
      refusal(op.run(params, auth))
    end
  end

  # As `FallbackController` words it, so REST and MCP refuse alike.
  defp refusal({:error, :forbidden, message}) when is_binary(message),
    do: {:error, "forbidden: " <> message}

  defp refusal(result), do: Args.refusal(result)

  defp confirmed(op, params, auth) do
    if op.definition()[:confirm], do: op.confirm(params, auth), else: :ok
  end
end
