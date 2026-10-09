defmodule Slipdock.Meetings.Export do
  @moduledoc """
  A capture written out for somebody to take away: the meeting, the
  transcript as received and its lines, what was found (with the words it
  came from), every question with how it was settled, and the record. People
  are named by email, never by an id on this server.

  Used by the account export (`Slipdock.AccountExport`, the captures a person
  sent) and the board export (`Slipdock.Portable.Export`, the captures on a
  board). The recording is bytes, not structure: it is named here, and only
  the account export carries the file, and only when asked.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Meetings
  alias Slipdock.Meetings.Capture
  alias Slipdock.Repo

  @doc "One capture as a map ready for JSON."
  def capture_json(%Capture{} = capture) do
    capture = Meetings.load(capture)
    voices = Map.new(capture.voices, &{&1.id, &1})
    people = people(capture)

    %{
      title: capture.title,
      state: capture.state,
      state_reason: capture.state_reason,
      started_at: capture.started_at,
      received_at: capture.inserted_at,
      sent_by: email(people, capture.owner_id),
      source: capture.source,
      attendees: capture.attendees,
      fingerprint: capture.fingerprint,
      transcript_format: capture.transcript_format,
      transcript: capture.transcript,
      audio:
        capture.audio_filename &&
          %{
            filename: capture.audio_filename,
            content_type: capture.audio_content_type,
            bytes: capture.audio_size,
            duration_ms: capture.audio_duration_ms,
            purged_at: capture.audio_purged_at
          },
      lines:
        Enum.map(capture.utterances, fn u ->
          %{
            id: u.line_id,
            start_ms: u.start_ms,
            end_ms: u.end_ms,
            speaker: u.speaker,
            voice: u.voice_id && voices[u.voice_id] && voices[u.voice_id].label,
            voice_unsure: u.voice_unsure,
            text: u.text
          }
        end),
      voices:
        Enum.map(capture.voices, fn v ->
          %{
            label: v.label,
            name: v.name,
            person: email(people, v.user_id),
            evidence: v.evidence,
            confirmed_by: email(people, v.confirmed_by_id),
            confirmed_at: v.confirmed_at
          }
        end),
      findings: Enum.map(capture.findings, &finding_json(&1, people)),
      questions:
        Enum.map(capture.questions, fn q ->
          %{
            kind: q.kind,
            prompt: q.prompt,
            options: q.options,
            blocking: q.blocking,
            status: q.status,
            answer: q.answer,
            answered_by: email(people, q.answered_by_id),
            answered_at: q.answered_at,
            via: q.via,
            context: q.context
          }
        end),
      record:
        Enum.map(capture.events, fn e ->
          %{
            at: e.inserted_at,
            kind: e.kind,
            message: e.message,
            by: email(people, e.user_id),
            via: e.via
          }
        end),
      committed_at: capture.committed_at,
      committed_by: email(people, capture.committed_by_id),
      discarded_at: capture.discarded_at,
      discarded_by: email(people, capture.discarded_by_id),
      undone_at: capture.undone_at,
      change_set: capture.change_set
    }
  end

  defp finding_json(finding, people) do
    %{
      kind: finding.kind,
      title: finding.title,
      body: finding.body,
      effect: finding.effect,
      included: finding.included,
      status: finding.status,
      drop_reason: finding.drop_reason,
      origin: finding.origin,
      signals: finding.signals,
      links: finding.links,
      edited_by: email(people, finding.edited_by_id),
      added_by: email(people, finding.added_by_id),
      evidence:
        Enum.map(finding.evidence, fn e ->
          %{
            line: e.line_id,
            from: e.char_start,
            to: e.char_end,
            quote: e.quote,
            speaker: e.speaker,
            at_ms: e.start_ms
          }
        end)
    }
  end

  # Everybody the capture names, looked up once.
  defp people(capture) do
    ids =
      [capture.owner_id, capture.committed_by_id, capture.discarded_by_id] ++
        Enum.flat_map(capture.voices, &[&1.user_id, &1.confirmed_by_id]) ++
        Enum.map(capture.questions, & &1.answered_by_id) ++
        Enum.flat_map(capture.findings, &[&1.edited_by_id, &1.added_by_id]) ++
        Enum.map(capture.events, & &1.user_id)

    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from(u in Slipdock.Accounts.User, where: u.id in ^ids, select: {u.id, u.email}))
    |> Map.new()
  end

  defp email(_people, nil), do: nil
  defp email(people, id), do: Map.get(people, id)

  @doc "The captures on these boards, oldest first."
  def on_boards(board_ids) do
    Repo.all(
      from(c in Capture,
        where: c.board_id in ^board_ids,
        order_by: [asc: c.inserted_at, asc: c.id]
      )
    )
  end

  @doc "The captures this person sent, on any board, oldest first."
  def sent_by(%Slipdock.Accounts.User{id: id}) do
    Repo.all(
      from(c in Capture,
        where: c.owner_id == ^id,
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: [:board]
      )
    )
  end
end
