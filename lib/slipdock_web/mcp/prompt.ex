defmodule SlipdockWeb.MCP.Prompt do
  @moduledoc """
  One MCP prompt: a ready-made workflow a client shows in its own menu (the
  `+` menu in Claude Desktop, `/mcp__slipdock__<name>` in Claude Code), and
  the text it starts the conversation with (W-1805).

  `render/2` gets the arguments as the client sent them (string keys, string
  values, already checked against `arguments/0`) and the same context a tool
  gets. It runs with the caller's token and embeds **live** board data, so
  the model starts from facts instead of spending its first calls finding
  them. It answers `{:ok, text}` — the body only: `SlipdockWeb.MCP.Prompts`
  puts the conventions, the read-only notice and the tools to use around it,
  and holds it to the size cap — or `{:error, message}`, which becomes a
  -32602 error naming what was wrong.
  """

  @type context :: SlipdockWeb.MCP.Tool.context()
  @type argument :: %{name: String.t(), description: String.t(), required: boolean()}

  @callback name() :: String.t()
  @callback title() :: String.t()
  @callback description() :: String.t()
  @callback arguments() :: [argument()]
  @doc "`true` when the workflow it starts will write to the board."
  @callback writes?() :: boolean()
  @doc "The MCP tools the workflow uses, named at the end of the rendered text."
  @callback tools() :: [String.t()]
  @doc "`false` while the feature it drives is off, so it is not listed. Left out, true."
  @callback available?() :: boolean()
  @optional_callbacks available?: 0
  @callback render(args :: %{optional(String.t()) => String.t()}, context()) ::
              {:ok, String.t()} | {:error, String.t()}
end
