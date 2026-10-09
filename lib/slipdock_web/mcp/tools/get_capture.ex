defmodule SlipdockWeb.MCP.Tools.GetCapture do
  @moduledoc """
  A meeting capture as an agent needs it: where it has got to, what it
  found (and what each finding would become), the questions a person has to
  answer, and the preview digest once it is ready to commit.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Meetings
  alias Slipdock.Meetings.{Commit, Describe, Verify}
  alias SlipdockWeb.API.MeetingJSON
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "get_capture"

  @impl true
  def title, do: "Read a meeting capture"

  @impl true
  def description,
    do:
      "A meeting capture: its state, what it found and what each finding becomes, and the open " <>
        "questions (each with numbered answers). Ask the person each question; never answer for them."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{capture: %{type: "integer", description: "The capture's id."}},
      required: ["capture"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    with {:ok, capture} <- fetch(args, context, :read) do
      {:ok, summary(capture, context)}
    end
  end

  @doc false
  # The capture `args["capture"]` names, if the token's user may `need` it.
  def fetch(args, context, need) do
    with {:ok, id} <- Args.required(args, "capture"),
         conn = Args.auth(context),
         {:ok, capture} <- Args.refusal(SlipdockWeb.API.MeetingController.fetch(conn, id, need)) do
      {:ok, capture}
    end
  end

  @doc false
  def summary(capture, context) do
    capture = Meetings.load(capture)
    kept = Enum.filter(capture.findings, &(&1.status == "kept"))

    %{
      id: capture.id,
      title: capture.title,
      state: capture.state,
      reason: capture.state_reason,
      url: MeetingJSON.url(context.base_url, capture),
      findings:
        Enum.map(kept, fn f ->
          %{
            id: f.id,
            kind: f.kind,
            title: f.title,
            included: f.included,
            becomes: Describe.becomes(f),
            signals: Enum.map(f.signals, &Verify.signal_label/1),
            said: Enum.map(f.evidence, &"#{&1.speaker || "?"}: “#{&1.quote}” (#{&1.line_id})")
          }
        end),
      dropped: Enum.count(capture.findings, &(&1.status == "dropped")),
      questions:
        capture.questions
        |> Enum.filter(&(&1.status in ["open", "waiting"]))
        |> Enum.map(fn q ->
          %{
            id: q.id,
            finding: q.finding_id,
            ask: q.prompt,
            status: q.status,
            answers:
              q.options |> Enum.with_index(1) |> Enum.map(fn {o, i} -> "#{i}. #{o["label"]}" end)
          }
        end),
      preview: if(capture.state == "ready", do: Commit.build(capture)["digest"])
    }
  end
end
