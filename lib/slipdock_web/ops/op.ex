defmodule SlipdockWeb.Ops.Op do
  @moduledoc """
  One definition of an operation, from which the
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
      (`top`, `bottom` or a 0-based place), or `:any` (passed to `run/2` as
      sent, for a value the operation reads itself; `schema` then gives the
      MCP schema for it). An `:integer` with `max` is a count with a ceiling
      (`limit`): it must be 1 or more, and more than `max` is taken as `max`
    * `cli` — `%{command, positional, flags}`: how argv maps onto `params`;
      left out when the CLI has no command for it

  and, optionally:

    * `status` — REST's status on success: an atom (`:created`), or a
      function of the result for an operation whose answer says which
      (default `:ok`)
    * `strict?` — `true` for one whose REST action refuses a field it
      doesn't name (400, "unknown field(s): …"), as MCP always refuses an
      argument its schema doesn't
    * `destructive?` — `true` for one that can't be undone (MCP's
      `destructiveHint`)
    * `confirm` — `%{type, doc}`: the `confirm` argument the MCP tool
      requires before it does anything that can't be undone, checked by
      `confirm/2`. MCP alone asks for it: a model drives that door, while
      REST's callers (the CLI, scripts) say what they mean by calling it (#3187)

  `run/2` gets the params already cast and checked, and the caller (a conn
  or the MCP context's `auth` map: `Authorize` takes either). It answers
  `{:ok, result}` with the one result shape every surface returns, or an
  error in the shape `FallbackController` and `MCP.Args.refusal/1` read.
  """

  @callback definition() :: map()
  @callback run(params :: map(), auth :: term()) :: {:ok, map()} | tuple()
  @doc """
  For a definition with `confirm`: `:ok` when the cast params' `"confirm"`
  says the caller means it, else the refusal. The MCP tool calls it before
  `run/2`.
  """
  @callback confirm(params :: map(), auth :: term()) :: :ok | tuple()
  @optional_callbacks confirm: 2
end
