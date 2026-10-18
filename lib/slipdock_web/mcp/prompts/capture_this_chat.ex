defmodule SlipdockWeb.MCP.Prompts.CaptureThisChat do
  @moduledoc """
  `capture-this-chat`: send the conversation so far through chat capture
  (#1045, `capture_chat`), so the decisions and to-dos in it become cards
  once the person has looked at the preview. Listed only while chat capture
  is on, like the tool it drives.
  """
  @behaviour SlipdockWeb.MCP.Prompt

  alias SlipdockWeb.MCP.Prompts.Context

  @doing 15

  @impl true
  def name, do: "capture-this-chat"

  @impl true
  def title, do: "Capture this chat"

  @impl true
  def description,
    do:
      "Sends this conversation to a board through chat capture: its decisions and " <>
        "to-dos become cards once you've checked the preview."

  @impl true
  def arguments,
    do: [
      %{name: "board", description: "The board to capture to (id, code or name).", required: true}
    ]

  @impl true
  def writes?, do: true

  @impl true
  def available?, do: Slipdock.Meetings.chat_enabled?()

  @impl true
  def tools,
    do: ["capture_chat", "get_capture", "resolve_capture_question", "commit_capture"]

  @impl true
  def render(%{"board" => ref}, context) do
    with {:ok, board} <- Context.board(context, ref) do
      roles = Context.roles(board)
      doing = (roles.doing && Enum.reject(roles.doing.cards, & &1.completed)) || []

      {:ok,
       """
       Capture this conversation onto #{Context.board_heading(board)}.

       Lists: #{Context.lists_line(board)}
       Tags: #{tags(board)}

       ## In progress there (so a decision about one of these goes on it, not a new card)
       #{doing |> Enum.map(&Context.card_line/1) |> Context.list(@doing, "list_cards")}

       1. Call capture_chat with board #{board.code || board.id}, a short title, and the \
       transcript: every turn of this conversation so far as "Name: text", mine under my \
       name and yours under "Assistant", copied word for word. Add findings only for what \
       I agreed to, each quoting the transcript exactly.
       2. Show me get_capture's preview: the cards, comments and pages it would write, \
       and any questions. Ask me the questions and record my answers with \
       resolve_capture_question.
       3. Call commit_capture only when I say so.
       """}
    end
  end

  defp tags(%{tags: [_ | _] = tags}), do: Enum.map_join(tags, ", ", & &1.name)
  defp tags(_), do: "none"
end
