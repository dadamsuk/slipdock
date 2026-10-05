defmodule SlipdockWeb.MCP.Tools do
  @moduledoc """
  The tools `/mcp` offers, and running one on somebody's behalf.

  The set is deliberately small and coarse: every schema here costs context in
  every session of every client that connects. Each tool calls the contexts
  directly and goes through `Slipdock.Access`, so what a tool can see and do is
  exactly what the HTTP API allows the same token.
  """

  alias SlipdockWeb.MCP.Tools

  @tools [
    Tools.Whoami,
    Tools.GetGuide,
    Tools.ListBoards,
    Tools.GetBoard,
    Tools.ListCards,
    Tools.GetCard,
    Tools.Search,
    Tools.ReadPage
  ]

  @doc "Every tool module, in the order `tools/list` gives them."
  def all, do: @tools

  @doc "The tool called `name`, or nil."
  def find(name), do: Enum.find(@tools, &(&1.name() == name))

  @doc "A tool as `tools/list` describes it."
  def describe(tool) do
    %{
      name: tool.name(),
      title: tool.title(),
      description: tool.description(),
      inputSchema: tool.input_schema(),
      annotations: annotations(tool)
    }
  end

  # Hints, not guarantees, as far as the client is concerned: it uses them to
  # decide what to run without asking. A write here never deletes anything —
  # there is no delete tool — so `destructiveHint` is false throughout and
  # `idempotentHint` is left unset.
  defp annotations(tool) do
    if tool.read_only?() do
      %{title: tool.title(), readOnlyHint: true, openWorldHint: false}
    else
      %{title: tool.title(), readOnlyHint: false, destructiveHint: false, openWorldHint: false}
    end
  end

  @doc """
  Runs `tool` for the context's token. Always a tool result — `{:ok, data}` or
  `{:error, message}` — whatever the tool does, so a bug in one tool comes back
  to the model as a failed call rather than taking the request down with it.
  """
  def call(tool, args, %{token: token} = context) when is_map(args) do
    if not tool.read_only?() and read_only_token?(token) do
      {:error,
       "this API token is read-only, so it can't #{tool.name()}. " <>
         "Don't retry: connect again with write access, or use a write token " <>
         "(Account → API tokens)."}
    else
      tool.call(args, context)
    end
  rescue
    e ->
      require Logger

      Logger.error(
        "MCP tool #{tool.name()} crashed: " <> Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, "#{tool.name()} failed on the server. Not worth retrying with the same arguments."}
  end

  def call(_tool, _args, _context), do: {:error, "arguments must be an object"}

  @doc """
  A card in a listing: enough to choose one, not to work it — `get_card` has
  the rest. Listings are what blow a client's per-result budget, so this
  leaves out descriptions, comments and checklists.
  """
  def card_line(card) do
    full = SlipdockWeb.API.JSON.card(card)

    full
    |> Map.take([
      :id,
      :title,
      :column,
      :position,
      :priority,
      :flags,
      :tags,
      :due_date,
      :completed,
      :percent_complete,
      :blocked
    ])
    |> Map.merge(%{
      assignees: Enum.map(full.assignees, & &1.email),
      blocked_by: Enum.map(full.blocked_by, & &1.id),
      subcards:
        full.sub_board &&
          %{board: full.sub_board.id, done: full.sub_board.completed, total: full.sub_board.total},
      stand_in_for: full.stand_in_for && full.stand_in_for.id
    })
  end

  defp read_only_token?(%{scope: "read"}), do: true
  defp read_only_token?(_), do: false
end
