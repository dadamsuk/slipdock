defmodule Slipdock.Meetings.Usage do
  @moduledoc """
  Meeting capture's usage ledger: every transcription, model call and stored
  recording, written as it happens against the person who sent the meeting,
  the capture and the month (see `Slipdock.Meetings.UsageEntry`) — and the
  limits on it, per person per month, which an admin sets in Configuration ›
  Meetings:

    * **transcription minutes** — what the server's transcription provider
      is asked to do; work on the person's own key or endpoint is theirs and
      does not count;
    * **audio stored** — the recordings they have on the server now (counted
      whoever's key transcribed them);
    * **captures from transcripts** — meetings sent without a recording;
    * and, for every meeting, the **longest meeting** and the **largest
      file** (`Slipdock.Meetings.Limits`).

  `check/3` runs before anything is stored or sent to a provider, and a
  meeting over a limit is refused with `meeting_limit_reached` — a 402 that
  says which limit, and that retrying will not help.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Meetings.{Capture, UsageEntry}
  alias Slipdock.Repo

  @doc """
  Writes one line. `attrs`: `:kind` (`transcription`, `reading`, `relisten`,
  `context`, `storage`), `:step`, `:seconds`, `:tokens_in`, `:tokens_out`,
  `:bytes`, `:cost`, `:model`, `:own_key`.
  """
  def record(%Capture{} = capture, attrs) do
    now = DateTime.utc_now()

    Repo.insert!(%UsageEntry{
      user_id: capture.owner_id,
      capture_id: capture.id,
      board_id: capture.board_id,
      kind: to_string(attrs[:kind]),
      step: attrs[:step] && to_string(attrs[:step]),
      seconds: attrs[:seconds] && attrs[:seconds] / 1,
      tokens_in: attrs[:tokens_in],
      tokens_out: attrs[:tokens_out],
      bytes: attrs[:bytes],
      cost: number(attrs[:cost]),
      model: attrs[:model],
      own_key: attrs[:own_key] == true,
      month: Date.beginning_of_month(DateTime.to_date(now)),
      inserted_at: now
    })
  end

  @doc """
  An `:on_usage` function for `Slipdock.AI.complete/2` that writes each model
  call to the ledger. A call on the person's own key or endpoint is marked
  `own_key`, which the server's limits leave out.
  """
  def recorder(%Capture{} = capture, kind, step, own_key?) do
    fn info ->
      record(capture, %{
        kind: kind,
        step: step,
        tokens_in: info.tokens_in,
        tokens_out: info.tokens_out,
        cost: info.cost,
        model: info.model,
        own_key: own_key? or info.custom?
      })
    end
  end

  @doc "A capture's ledger lines, oldest first."
  def for_capture(%Capture{id: id}) do
    Repo.all(from(u in UsageEntry, where: u.capture_id == ^id, order_by: [asc: u.id]))
  end

  defp number(nil), do: nil
  defp number(n) when is_number(n), do: n / 1

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  ## Totals ---------------------------------------------------------------------

  @doc "The first day of this month."
  def this_month, do: Date.beginning_of_month(Date.utc_today())

  @doc """
  One person's use this month, from the ledger: `transcription_seconds` and
  `tokens_in`/`tokens_out`/`cost` (each also `own_*`, what their own key or
  endpoint did), plus `transcript_captures` (meetings sent this month with no
  recording) and `audio_bytes` (recordings they have stored now).
  """
  def month(%{id: user_id}, month \\ this_month()) do
    row =
      Repo.one(
        from(u in UsageEntry,
          where: u.user_id == ^user_id and u.month == ^month,
          select: %{
            transcription_seconds:
              sum(
                fragment(
                  "CASE WHEN ? AND NOT ? THEN ? ELSE 0 END",
                  u.kind == "transcription",
                  u.own_key,
                  u.seconds
                )
              ),
            own_transcription_seconds:
              sum(
                fragment(
                  "CASE WHEN ? AND ? THEN ? ELSE 0 END",
                  u.kind == "transcription",
                  u.own_key,
                  u.seconds
                )
              ),
            tokens_in: sum(u.tokens_in),
            tokens_out: sum(u.tokens_out),
            cost: sum(fragment("CASE WHEN NOT ? THEN ? ELSE 0 END", u.own_key, u.cost)),
            own_cost: sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", u.own_key, u.cost))
          }
        )
      )

    %{
      transcription_seconds: num(row.transcription_seconds),
      own_transcription_seconds: num(row.own_transcription_seconds),
      tokens_in: int(row.tokens_in),
      tokens_out: int(row.tokens_out),
      cost: num(row.cost),
      own_cost: num(row.own_cost),
      transcript_captures: transcript_captures(user_id, month),
      audio_bytes: audio_bytes(user_id)
    }
  end

  defp transcript_captures(user_id, month) do
    from_dt = DateTime.new!(month, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(Date.shift(month, month: 1), ~T[00:00:00], "Etc/UTC")

    Repo.aggregate(
      from(c in Capture,
        where:
          c.owner_id == ^user_id and is_nil(c.audio_key) and is_nil(c.audio_purged_at) and
            not is_nil(c.transcript) and c.inserted_at >= ^from_dt and c.inserted_at < ^to_dt
      ),
      :count
    )
  end

  defp audio_bytes(user_id) do
    Repo.one(
      from(c in Capture,
        where: c.owner_id == ^user_id and not is_nil(c.audio_key),
        select: type(sum(c.audio_size), :integer)
      )
    ) || 0
  end

  @doc """
  The admin's limits as they stand: `%{transcription_minutes:, audio_storage_mb:,
  transcript_captures:, longest_minutes:, max_file_mb:}`, nil for a limit
  switched off.
  """
  def limits do
    s = Slipdock.Settings.get()

    %{
      transcription_minutes:
        if(s.meetings_transcription_minutes_enabled, do: s.meetings_transcription_minutes),
      audio_storage_mb: if(s.meetings_audio_storage_mb_enabled, do: s.meetings_audio_storage_mb),
      transcript_captures:
        if(s.meetings_transcript_captures_enabled, do: s.meetings_transcript_captures),
      longest_minutes: s.meetings_longest_minutes,
      max_file_mb: s.meetings_max_file_mb
    }
  end

  @doc """
  What this person has left this month, for the upload page: each limit as
  `%{used:, limit:, left:}` (`limit` nil when there is none), and whether
  transcription and reading are on their own key.
  """
  def allowance(%User{} = user) do
    used = month(user)
    limits = limits()

    %{
      own_key?: Slipdock.AI.Keys.own?(user),
      transcription_minutes:
        line(div(round(used.transcription_seconds), 60), limits.transcription_minutes),
      audio_storage_mb: line(div(used.audio_bytes, 1024 * 1024), limits.audio_storage_mb),
      transcript_captures: line(used.transcript_captures, limits.transcript_captures)
    }
  end

  defp line(used, nil), do: %{used: used, limit: nil, left: nil}
  defp line(used, limit), do: %{used: used, limit: limit, left: max(limit - used, 0)}

  @doc """
  Whether this person may send a meeting: `want` says what it would use —
  `transcript_capture: true`, `audio_bytes: n`, `transcription_seconds: n`.
  `:ok`, or `{:error, {:limit, "meeting_limit_reached", message}}` naming
  the limit. Transcription on the person's own key or endpoint is not
  counted; storage always is.
  """
  def check(%User{} = user, want) do
    used = month(user)
    limits = limits()
    own? = Slipdock.AI.Keys.own?(user)

    cond do
      want[:transcript_capture] && limits.transcript_captures &&
          used.transcript_captures + 1 > limits.transcript_captures ->
        limit(
          "You've sent #{used.transcript_captures} meetings as transcripts this month, the most this server allows (#{limits.transcript_captures})."
        )

      (want[:audio_bytes] || 0) > 0 && limits.audio_storage_mb &&
          used.audio_bytes + want[:audio_bytes] > limits.audio_storage_mb * 1024 * 1024 ->
        limit(
          "This recording would take your stored meeting audio past the #{limits.audio_storage_mb} MB this server allows each person " <>
            "(#{div(used.audio_bytes, 1024 * 1024)} MB stored now). Recordings already committed or expired free it."
        )

      (not own? and (want[:transcription_seconds] || 0) > 0) && limits.transcription_minutes &&
          used.transcription_seconds + want[:transcription_seconds] >
            limits.transcription_minutes * 60 ->
        left = max(limits.transcription_minutes - div(round(used.transcription_seconds), 60), 0)

        limit(
          "Transcribing this (about #{max(div(round(want[:transcription_seconds]), 60), 1)} minutes) would take you past this month's " <>
            "#{limits.transcription_minutes} transcription minutes (#{left} left). Send a transcript with the recording, " <>
            "or transcribe on your own AI key."
        )

      true ->
        :ok
    end
  end

  defp limit(message), do: {:error, {:limit, "meeting_limit_reached", message}}

  @doc """
  The server's month, for the admin: totals across everybody, and the
  heaviest users (by what they cost the server, then transcription).
  """
  def server_month(month \\ this_month()) do
    shared = from(u in UsageEntry, where: u.month == ^month and not u.own_key)

    totals =
      Repo.one(
        from(u in shared,
          select: %{
            transcription_seconds:
              sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", u.kind == "transcription", u.seconds)),
            tokens: sum(coalesce(u.tokens_in, 0) + coalesce(u.tokens_out, 0)),
            cost: sum(u.cost),
            people: count(u.user_id, :distinct)
          }
        )
      )

    heaviest =
      Repo.all(
        from(u in shared,
          join: p in assoc(u, :user),
          group_by: [p.id, p.email, p.name],
          select: %{
            email: p.email,
            name: p.name,
            transcription_seconds:
              sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", u.kind == "transcription", u.seconds)),
            tokens: sum(coalesce(u.tokens_in, 0) + coalesce(u.tokens_out, 0)),
            cost: sum(u.cost)
          },
          order_by: [
            desc_nulls_last: sum(u.cost),
            desc:
              sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", u.kind == "transcription", u.seconds))
          ],
          limit: 5
        )
      )

    %{
      month: month,
      transcription_minutes: div(round(num(totals.transcription_seconds)), 60),
      tokens: int(totals.tokens),
      cost: num(totals.cost),
      people: totals.people,
      audio_bytes:
        Repo.one(
          from(c in Capture,
            where: not is_nil(c.audio_key),
            select: type(sum(c.audio_size), :integer)
          )
        ) || 0,
      heaviest:
        Enum.map(heaviest, fn h ->
          %{
            h
            | transcription_seconds: num(h.transcription_seconds),
              tokens: int(h.tokens),
              cost: num(h.cost)
          }
        end)
    }
  end

  defp num(nil), do: 0.0
  defp num(%Decimal{} = d), do: Decimal.to_float(d)
  defp num(n) when is_number(n), do: n / 1

  defp int(nil), do: 0
  defp int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: round(n)
end
