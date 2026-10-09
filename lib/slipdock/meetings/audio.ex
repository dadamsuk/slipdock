defmodule Slipdock.Meetings.Audio do
  @moduledoc """
  Pipeline step 2: turning a recording into transcript lines, or lining a
  supplied transcript up with the recording. A capture with a transcript
  and no recording has nothing to do here.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Meetings.{Capture, Utterance}

  @doc """
  `{:ok, capture}` once the capture has lines to read, or `{:error, reason}`:

    * a transcript alone: nothing to do;
    * a transcript and a recording: the transcript's lines are lined up with
      the recording (`align/1`), their words untouched;
    * a recording alone: transcribed (`Slipdock.Meetings.Transcriber`), after
      checking the sender has the minutes left — before anything is sent.
  """
  def transcribe(%Capture{transcript: t, audio_key: nil} = capture, _opts) when is_binary(t),
    do: {:ok, capture}

  def transcribe(%Capture{transcript: t} = capture, _opts) when is_binary(t), do: align(capture)

  def transcribe(%Capture{audio_key: key} = capture, opts) when is_binary(key) do
    owner = Repo.get!(Slipdock.Accounts.User, capture.owner_id)
    seconds = div(capture.audio_duration_ms || 0, 1000)

    with :ok <- allowance(owner, seconds),
         {:ok, lines} <- Slipdock.Meetings.Transcriber.transcribe(capture, owner, opts) do
      :ok = Meetings.put_utterances(capture, lines)

      {:ok,
       capture
       |> Ecto.Changeset.change(
         transcript_format: "transcribed",
         sources: Map.put(capture.sources, "transcribed", %{"lines" => length(lines)})
       )
       |> Repo.update!()}
    end
  end

  def transcribe(%Capture{}, _opts), do: {:error, "there is no transcript or recording to read"}

  defp allowance(owner, seconds) do
    case Slipdock.Meetings.Usage.check(owner, transcription_seconds: seconds) do
      :ok -> :ok
      {:error, {:limit, _code, message}} -> {:error, message}
    end
  end

  @doc """
  Lines a supplied transcript up with its recording, without changing a
  word of it. A transcript with its own times (WebVTT, SRT, an export) is
  already lined up. One without is spread over the recording's length in
  proportion to how much was said before each line — an estimate, marked as
  one (`sources["alignment"] == "estimated"`), good enough to find a passage
  to replay.
  """
  def align(%Capture{} = capture) do
    lines =
      Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id, order_by: u.position))

    cond do
      lines == [] or Enum.all?(lines, &is_integer(&1.start_ms)) ->
        {:ok, mark(capture, "from the transcript")}

      is_nil(capture.audio_duration_ms) ->
        {:ok, mark(capture, "none")}

      true ->
        total = lines |> Enum.map(&String.length(&1.text)) |> Enum.sum() |> max(1)

        {starts, _} =
          Enum.map_reduce(lines, 0, fn u, before ->
            {div(capture.audio_duration_ms * before, total), before + String.length(u.text)}
          end)

        ends = tl(starts) ++ [capture.audio_duration_ms]

        Repo.transaction(fn ->
          for {u, {start, stop}} <- Enum.zip(lines, Enum.zip(starts, ends)) do
            Repo.update_all(from(x in Utterance, where: x.id == ^u.id),
              set: [start_ms: start, end_ms: stop]
            )
          end
        end)

        {:ok, mark(capture, "estimated")}
    end
  end

  defp mark(capture, how) do
    capture
    |> Ecto.Changeset.change(sources: Map.put(capture.sources || %{}, "alignment", how))
    |> Repo.update!()
  end

  @doc """
  Deletes recordings past their keeping (the capture's `retention`): when it
  was committed or discarded for `until_committed`, else 30 or 90 days after
  it arrived. The file goes and the storage it was counted against is freed;
  the capture keeps saying a recording was there, and that replay is gone.
  Returns how many were deleted. Run by the scheduler's clock.
  """
  def purge_expired(now \\ DateTime.utc_now()) do
    days = fn n -> DateTime.add(now, -n * 86_400, :second) end

    Repo.all(
      from(c in Capture,
        where:
          not is_nil(c.audio_key) and
            ((c.retention == "until_committed" and c.state in ["committed", "discarded"]) or
               (c.retention == "30_days" and c.inserted_at < ^days.(30)) or
               (c.retention == "90_days" and c.inserted_at < ^days.(90)))
      )
    )
    |> Enum.map(&purge/1)
    |> length()
  end

  @doc "Deletes one capture's recording now."
  def purge(%Capture{audio_key: nil} = capture), do: capture

  def purge(%Capture{audio_key: key} = capture) do
    capture =
      capture
      |> Ecto.Changeset.change(
        audio_key: nil,
        audio_purged_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update!()

    Slipdock.Boards.remove_files([key])

    Meetings.record(
      capture,
      "audio_deleted",
      "Deleted the recording (kept #{retention_words(capture.retention)}); replay is no longer possible."
    )

    Meetings.broadcast(capture)
    capture
  end

  defp retention_words("until_committed"), do: "until committed"
  defp retention_words("30_days"), do: "for 30 days"
  defp retention_words("90_days"), do: "for 90 days"
  defp retention_words(other), do: other

  @doc """
  How long a recording runs, in milliseconds, before anything has listened
  to it: exact for WAV (from its header), otherwise estimated from its size
  at 128 kbit/s — what the limits are checked against before a recording is
  sent anywhere. The provider's own count is what the ledger records after.
  """
  def duration_ms(path, filename \\ nil) do
    ext = (filename || path) |> Path.extname() |> String.downcase()

    with ".wav" <- ext,
         {:ok, ms} <- wav_ms(path) do
      ms
    else
      _ -> estimate_ms(File.stat!(path).size)
    end
  end

  @doc false
  def estimate_ms(bytes), do: div(bytes * 1000, 16_000)

  # RIFF/WAVE: the fmt chunk's byte rate, and the data chunk's size.
  defp wav_ms(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 4096)) do
      {:ok, <<"RIFF", _::32, "WAVE", chunks::binary>>} -> wav_chunks(chunks, nil)
      _ -> :error
    end
  end

  defp wav_chunks(<<"fmt ", size::little-32, fmt::binary-size(size), rest::binary>>, _rate) do
    <<_format::little-16, _channels::little-16, _sample_rate::little-32, byte_rate::little-32,
      _::binary>> = fmt

    wav_chunks(rest, byte_rate)
  end

  defp wav_chunks(<<"data", size::little-32, _::binary>>, rate)
       when is_integer(rate) and rate > 0,
       do: {:ok, div(size * 1000, rate)}

  defp wav_chunks(<<_id::binary-size(4), size::little-32, rest::binary>>, rate)
       when byte_size(rest) >= size do
    <<_::binary-size(^size), more::binary>> = rest
    wav_chunks(more, rate)
  end

  defp wav_chunks(_, _), do: :error
end
