defmodule SlipdockWeb.MCP.Tools.CaptureMeeting do
  @moduledoc """
  Sends a meeting's transcript to a board for meeting capture (see
  `Slipdock.Meetings`), optionally with the agent's own findings, which are
  checked word for word like Slipdock's. Only offered while meeting mode is on.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Meetings.Ingest
  alias SlipdockWeb.API.{Authorize, MeetingJSON}
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.GetCapture

  @impl true
  def name, do: "capture_meeting"

  @impl true
  def title, do: "Send a meeting transcript"

  @impl true
  def description,
    do:
      "Sends a meeting transcript (WebVTT, SRT, \"Name: words\" lines, Fireflies or Otter export) to a " <>
        "board. Slipdock reads it with the board's cards and wiki and proposes decisions, actions and card " <>
        "changes for a person to review; nothing is written until they commit. Optional findings follow " <>
        "the schema at /api/meetings/findings-schema. Recordings: use the CLI or the API."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        transcript: %{type: "string", description: "The transcript's text, as exported."},
        title: %{type: "string"},
        when: %{type: "string", description: "When the meeting started, ISO 8601."},
        attendees: %{type: "string", description: "Names and/or emails, comma-separated."},
        format: %{type: "string", enum: Slipdock.Meetings.Transcript.formats()},
        findings: %{
          type: "object",
          description: "Your own findings: {\"findings\": [...]}, optional."
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
         {:ok, at} <- Args.optional(args, "when"),
         {:ok, attendees} <- Args.optional(args, "attendees"),
         {:ok, format} <- Args.optional(args, "format"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :write)) do
      findings =
        case args["findings"] do
          %{} = doc -> %{content: Jason.encode!(doc)}
          _ -> nil
        end

      result =
        Ingest.ingest(board, context.user, %{
          transcript: %{content: args["transcript"] || transcript, filename: nil},
          findings: findings,
          title: title,
          started_at: at,
          attendees: attendees,
          format: format,
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

        {:error, %Ecto.Changeset{} = cs} ->
          Args.refusal({:error, cs})
      end
    end
  end

  @doc false
  def url(context, capture), do: MeetingJSON.url(context.base_url, capture)
end
