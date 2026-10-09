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
    Tools.ReadPage,
    Tools.ListPages,
    Tools.PageInfo,
    Tools.PageHistory,
    Tools.Activity,
    Tools.CreateCard,
    Tools.UpdateCard,
    Tools.MoveCard,
    Tools.Comment,
    Tools.CompleteCard,
    Tools.ArchiveCard,
    Tools.DeleteCard,
    Tools.CreateList,
    Tools.DeleteList,
    Tools.CreateBoard,
    Tools.ArchiveBoard,
    Tools.DeleteBoard,
    Tools.WritePage,
    Tools.UpdatePage,
    Tools.RevertPage,
    Tools.ClaimJob,
    Tools.JobProgress,
    Tools.FinishJob
  ]

  # Meeting capture's tools (see `Slipdock.Meetings`): listed, and callable,
  # only while an admin has meeting mode on. Off, a client is not shown them
  # and calling one by name is an unknown tool, the same as any other name
  # this server has never heard of.
  @meeting_tools []

  @doc "Every tool module offered right now, in the order `tools/list` gives them."
  def all do
    if Slipdock.Meetings.enabled?(), do: @tools ++ @meeting_tools, else: @tools
  end

  @doc "Every tool this server has, meeting mode or not: what the docs must describe."
  def every, do: @tools ++ @meeting_tools

  @doc "Meeting capture's tools, which only exist while meeting mode is on."
  def meeting_tools, do: @meeting_tools

  @doc "The tool called `name`, or nil — nil too for a tool not offered right now."
  def find(name), do: Enum.find(all(), &(&1.name() == name))

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
  # decide what to run without asking. `destructiveHint` marks the writes that
  # can overwrite what somebody wrote, and the deletes, which nothing undoes —
  # archiving, which restoring undoes, is not destructive.
  defp annotations(tool) do
    if tool.read_only?() do
      %{title: tool.title(), readOnlyHint: true, openWorldHint: false}
    else
      Code.ensure_loaded(tool)
      destructive = function_exported?(tool, :destructive?, 0) and tool.destructive?()

      %{
        title: tool.title(),
        readOnlyHint: false,
        destructiveHint: destructive,
        openWorldHint: false
      }
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
  the rest. The description is in, so an agent can tell what each card is
  about without a `get_card` per card; comments and checklists are left out,
  since listings are what blow a client's per-result budget.
  """
  def card_line(card) do
    full = SlipdockWeb.API.JSON.card(card)

    full
    |> Map.take([
      :id,
      :title,
      :description,
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
    |> then(&if(full.archived_at, do: Map.put(&1, :archived, true), else: &1))
  end

  @doc "A card written by a tool, as the tool answers it: the card in brief and where it is."
  def card_written(card, base_url) do
    card
    |> card_line()
    |> Map.merge(%{
      board_id: card.board_id,
      url: base_url <> "/boards/#{card.board_id}/cards/#{card.id}"
    })
  end

  defp read_only_token?(%{scope: "read"}), do: true
  defp read_only_token?(_), do: false
end
