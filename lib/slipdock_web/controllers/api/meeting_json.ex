defmodule SlipdockWeb.API.MeetingJSON do
  @moduledoc """
  Meeting capture as the API, the CLI and MCP see it (see `Slipdock.Meetings`).
  Plain maps, like `SlipdockWeb.API.JSON`; people are emails.
  """

  alias Slipdock.Meetings.{Capture, Evidence, Finding, Question}

  @doc "Where a capture is read and reviewed in the web app."
  def url(base, %Capture{} = c), do: "#{base}/boards/#{c.board_id}/meetings/#{c.id}"

  @doc "A capture without its contents: for lists, and the answer to sending one."
  def summary(%Capture{} = c, base \\ "") do
    %{
      id: c.id,
      board_id: c.board_id,
      title: c.title,
      state: c.state,
      state_reason: c.state_reason,
      step: c.step,
      progress: c.progress,
      started_at: c.started_at,
      received_at: c.inserted_at,
      source: c.source,
      sent_by: email(c.owner),
      attendees: c.attendees,
      inputs: %{
        transcript: Map.has_key?(c.sources, "transcript"),
        audio: c.audio_key != nil,
        findings: Map.has_key?(c.sources, "findings")
      },
      context: c.context_scope,
      retention: c.retention,
      committed_at: c.committed_at,
      committed_by: email(c.committed_by),
      discarded_at: c.discarded_at,
      discarded_by: email(c.discarded_by),
      undone_at: c.undone_at,
      url: url(base, c)
    }
  end

  @doc "A capture in full: its lines, findings, questions and record."
  def capture(%Capture{} = c, base \\ "") do
    findings = loaded(c.findings)
    questions = loaded(c.questions)

    c
    |> summary(base)
    |> Map.merge(%{
      counts: %{
        lines: length(loaded(c.utterances)),
        findings: Enum.count(findings, &(&1.status == "kept")),
        included: Enum.count(findings, &(&1.status == "kept" and &1.included)),
        dropped: Enum.count(findings, &(&1.status == "dropped")),
        open_questions: Enum.count(questions, &Slipdock.Meetings.blocks?(&1, findings))
      },
      lines:
        Enum.map(loaded(c.utterances), fn u ->
          %{
            id: u.line_id,
            start_ms: u.start_ms,
            end_ms: u.end_ms,
            speaker: u.speaker,
            text: u.text
          }
        end),
      findings: Enum.map(findings, &finding/1),
      questions: Enum.map(questions, &question/1),
      record:
        Enum.map(loaded(c.events), fn e ->
          %{at: e.inserted_at, kind: e.kind, message: e.message, by: email(e.user), via: e.via}
        end)
    })
  end

  def finding(%Finding{} = f) do
    %{
      id: f.id,
      kind: f.kind,
      title: f.title,
      body: f.body,
      effect: f.effect,
      included: f.included,
      status: f.status,
      drop_reason: f.drop_reason,
      origin: f.origin,
      signals: f.signals,
      links: f.links,
      known: f.known,
      becomes: Slipdock.Meetings.Describe.becomes(f),
      edited_by: email(f.edited_by),
      evidence: Enum.map(loaded(f.evidence), &evidence/1)
    }
  end

  def evidence(%Evidence{} = e),
    do: %{line: e.line_id, from: e.char_start, to: e.char_end, quote: e.quote, speaker: e.speaker}

  def question(%Question{} = q) do
    %{
      id: q.id,
      finding_id: q.finding_id,
      kind: q.kind,
      prompt: q.prompt,
      options: q.options,
      blocking: q.blocking,
      status: q.status,
      answer: q.answer,
      answered_by: email(q.answered_by),
      answered_at: q.answered_at,
      via: q.via,
      context: q.context
    }
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: []
  defp loaded(nil), do: []
  defp loaded(list), do: list

  defp email(%{email: email}), do: email
  defp email(_), do: nil
end
