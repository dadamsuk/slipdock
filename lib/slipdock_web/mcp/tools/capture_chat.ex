defmodule SlipdockWeb.MCP.Tools.CaptureChat do
  @moduledoc """
  Sends the conversation the calling model is having to a board for chat
  capture (#1076, see `Slipdock.Meetings`): the conversation as `Name: text`
  turns or a Claude or ChatGPT export, optionally with the model's own
  findings — read by the model itself, so no server model or AI key is
  needed — which are checked word for word against the conversation like any
  other. Only offered while chat capture is on.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Meetings.Ingest
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.GetCapture

  @formats ~w(chat claude-export chatgpt-export)

  @impl true
  def name, do: "capture_chat"

  @impl true
  def title, do: "Capture this conversation"

  @impl true
  def description,
    do:
      "Sends this conversation to a board so the decisions and to-dos in it can be committed as cards. " <>
        "transcript: the conversation as \"Name: text\" turns, the person's turns under their name and yours " <>
        "under \"Assistant\", copied word for word (or a Claude/ChatGPT export with format). findings " <>
        "(optional, schema at /api/meetings/findings-schema): your own reading — only what the person " <>
        "agreed to, each quoting the transcript exactly; quotes not in it are dropped. Without findings the " <>
        "server reads it. Nothing is written until commit_capture: show the person get_capture's preview " <>
        "and commit only when they say so."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        transcript: %{
          type: "string",
          description: "The conversation: \"Name: text\" turns, or an export's JSON."
        },
        title: %{type: "string", description: "What the conversation was about."},
        format: %{type: "string", enum: @formats, description: "Detected when left out."},
        conversation: %{
          type: "string",
          description: "From an export holding several conversations: the id or title of one."
        },
        findings: %{
          type: "object",
          description: "Your own findings: {\"findings\": [...], \"summary\"?, \"topics\"?}."
        },
        keep_transcript: %{
          type: "boolean",
          description:
            "false: once committed, the conversation's lines are deleted and only the quoted words kept."
        }
      },
      required: ["board", "transcript"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, transcript} <- Args.required(args, "transcript"),
         {:ok, title} <- Args.optional(args, "title"),
         {:ok, format} <- Args.optional(args, "format"),
         {:ok, conversation} <- Args.optional(args, "conversation"),
         :ok <- known_format(format),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :write)) do
      findings =
        case args["findings"] do
          %{} = doc -> %{content: Jason.encode!(doc)}
          _ -> nil
        end

      result =
        Ingest.ingest(board, context.user, %{
          kind: "chat",
          transcript: %{content: args["transcript"] || transcript, filename: nil},
          findings: findings,
          title: title,
          format: format,
          conversation: conversation,
          keep_transcript: args["keep_transcript"],
          source: "agent",
          via: "mcp"
        })

      case result do
        {:ok, capture} ->
          {:ok, Map.put(GetCapture.summary(capture, context), :existing, false)}

        {:existing, capture} ->
          {:ok, Map.put(GetCapture.summary(capture, context), :existing, true)}

        {:error, {:invalid, message}} ->
          {:error, message}

        {:error, {:limit, _code, message}} ->
          {:error, message}

        {:error, %Ecto.Changeset{} = cs} ->
          Args.refusal({:error, cs})
      end
    end
  end

  defp known_format(nil), do: :ok
  defp known_format(format) when format in @formats, do: :ok

  defp known_format(format),
    do: {:error, "#{inspect(format)} is not a chat format (use #{Enum.join(@formats, ", ")})"}
end
