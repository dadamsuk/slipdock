defmodule SlipdockWeb.Ops.MCPTool do
  @moduledoc """
  An MCP tool made from an operation's definition.
  `use SlipdockWeb.Ops.MCPTool, op: SlipdockWeb.Ops.MoveCard` is the whole tool.
  """

  defmacro __using__(op: op) do
    quote do
      @behaviour SlipdockWeb.MCP.Tool
      @op unquote(op)

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
      def call(args, context) do
        auth = SlipdockWeb.MCP.Args.auth(context)

        with {:ok, params} <- SlipdockWeb.MCP.Args.refusal(SlipdockWeb.Ops.cast(@op, args)) do
          SlipdockWeb.MCP.Args.refusal(@op.run(params, auth))
        end
      end
    end
  end
end
