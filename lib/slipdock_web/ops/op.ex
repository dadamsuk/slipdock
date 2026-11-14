defmodule SlipdockWeb.Ops.Op do
  @moduledoc """
  Spike #3165 (never merged): one definition of an operation, from which the
  REST action, the MCP tool, the CLI command and the guide's reference line
  all come.

  `definition/0` is plain data:

    * `name` — the operation's one name (`move_card`), the MCP tool's too
    * `title`, `summary` — the MCP title and description, the reference line
    * `verb`, `path` — the REST route (`path` as the router writes it)
    * `permission` — what the caller needs, `{:card, :write}` and so on
    * `writes?` — whether it changes anything (a read-scope token's test)
    * `params` — `[%{name, type, required, default, doc}]`, `type` one of
      `:integer`, `:string`, `:boolean`, `{:enum, [..]}`, `:position`
      (`top`, `bottom` or a 0-based place)
    * `cli` — `%{command, positional, flags}`: how argv maps onto `params`

  `run/2` gets the params already cast and checked, and the caller (a conn
  or the MCP context's `auth` map: `Authorize` takes either). It answers
  `{:ok, result}` with the one result shape every surface returns, or an
  error in the shape `FallbackController` and `MCP.Args.refusal/1` read.
  """

  @callback definition() :: map()
  @callback run(params :: map(), auth :: term()) :: {:ok, map()} | tuple()
end
