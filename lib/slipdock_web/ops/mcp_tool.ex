defmodule SlipdockWeb.Ops.MCPTool do
  @moduledoc """
  An MCP tool made from an operation's definition.
  `use SlipdockWeb.Ops.MCPTool, op: SlipdockWeb.Ops.MoveCard` is the whole tool;
  what it does on a call is `SlipdockWeb.Ops.MCPCall`'s. This module is the
  macro alone, with nothing of its own to call, so a tool made with it
  depends on nothing at compile time but it (`BoundariesTest`).
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
      def destructive?, do: SlipdockWeb.Ops.MCPCall.destructive?(@op)

      @impl true
      def call(args, context) do
        SlipdockWeb.Ops.MCPCall.call(@op, args, SlipdockWeb.MCP.Args.auth(context))
      end
    end
  end
end
