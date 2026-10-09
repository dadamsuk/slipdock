defmodule Slipdock.Meetings.Audio do
  @moduledoc """
  Pipeline step 2: turning a recording into transcript lines, or lining a
  supplied transcript up with the recording. A capture with a transcript
  and no recording has nothing to do here.
  """

  alias Slipdock.Meetings.Capture

  @doc "`{:ok, capture}` once the capture has lines to read, or `{:error, reason}`."
  def transcribe(%Capture{transcript: transcript} = capture, _opts) when is_binary(transcript),
    do: {:ok, capture}

  def transcribe(%Capture{audio_key: key}, _opts) when is_binary(key),
    do:
      {:error,
       "this server transcribes nothing yet, so a recording needs a transcript sent with it"}

  def transcribe(%Capture{}, _opts), do: {:error, "there is no transcript or recording to read"}

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
