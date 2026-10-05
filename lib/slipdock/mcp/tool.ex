defmodule Slipdock.MCP.Tool do
  @moduledoc """
  One MCP tool: what a client is shown in `tools/list`, and what happens on
  `tools/call`.

  `call/2` gets the arguments as the client sent them (string keys) and a
  context — the token's `user`, the `token` row itself and the `base_url` the
  client reached us on. It answers `{:ok, data}`, which becomes the tool's
  result, or `{:error, message}`, which becomes a result with `isError: true`.
  A tool's failure is something for the model to read and act on, never a
  JSON-RPC error (see W-21).

  Keep descriptions short: every one of them is loaded into the client's
  context at the start of every session.
  """

  @type context :: %{user: struct(), token: struct(), base_url: String.t()}

  @callback name() :: String.t()
  @callback title() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @doc "`true` for a tool that changes nothing. A read-scope token may call only these."
  @callback read_only?() :: boolean()
  @callback call(args :: map(), context()) :: {:ok, term()} | {:error, String.t()}
end
