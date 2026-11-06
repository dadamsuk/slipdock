defmodule SlipdockWeb.MCP.Tool do
  @moduledoc """
  One MCP tool: what a client is shown in `tools/list`, and what happens on
  `tools/call`.

  `call/2` gets the arguments as the client sent them (string keys) and a
  context — the token's `user`, the `token` row itself and the `base_url` the
  client reached us on. It answers `{:ok, data}`, which becomes the tool's
  result, `{:ok, data, content}` when the tool adds MCP content blocks of its
  own after the JSON (a file's bytes, `download_file`), or `{:error, message}`, which becomes a result with `isError: true`.
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
  @doc """
  `true` for a tool that changes nothing whatever it is called with: it is
  what `tools/list` tells the client (`readOnlyHint`), so a tool that writes
  only for some arguments is `false` here and says which in `writes?/1`.
  """
  @callback read_only?() :: boolean()
  @doc """
  Whether this call, with these arguments, changes anything: a read-scope
  token may make only the calls that don't. Left out, `not read_only?()`.
  """
  @callback writes?(args :: map()) :: boolean()
  @doc "`true` for a write that can overwrite what is there. Left out, false."
  @callback destructive?() :: boolean()
  @optional_callbacks destructive?: 0, writes?: 1
  @callback call(args :: map(), context()) ::
              {:ok, term()} | {:ok, map(), [map()]} | {:error, String.t()}
end
