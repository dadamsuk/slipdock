defmodule Slipdock.Transcription.Voiceprints do
  @moduledoc """
  Teaching the transcription server a voice (#1201).

  When somebody puts a name on a voice — in a wiki page's transcript
  (`Slipdock.Wiki.rename_speaker/4`) or on a meeting capture's *Who said
  what* (`Slipdock.Meetings.Speakers.reassign/3`) — the longest unbroken
  stretch of that person speaking is cut from the recording and sent to the
  transcription server (`Slipdock.Transcription.add_voiceprint/3`) under
  that name, so the next recording it transcribes can say it was them.

    * **Off unless an admin turns it on** (`transcription_voiceprints`), and
      only on a server that lists `"voiceprints"` in its capabilities. It is
      somebody's voice going to the admin's own server, so it is never on by
      default.
    * **Only a person's name.** "Speaker 2" teaches nothing
      (`Slipdock.Meetings.Speakers.person_label?/1`).
    * **One stretch**: consecutive lines of theirs with nobody else between,
      the longest of them, kept clear of anybody else's line that overlaps
      it and half a second in from each end, cut to at most 60 s; under 3 s
      is too little to send. A server that refuses the clip (a 422, such as
      "Multiple speakers") is offered the next-longest, up to three.
    * **In the background**, after the name is saved: the recording may have
      to come from Google Drive first. What happens is logged, and on a
      capture recorded in its history.
  """
  require Logger

  import Ecto.Query, warn: false

  alias Slipdock.{Meetings, Recordings, Repo, Settings, Transcription, Vaults}
  alias Slipdock.Google.Drive
  alias Slipdock.Meetings.{Capture, Relisten, Speakers, Transcript, Utterance, Voice}
  alias Slipdock.Wiki.{FrontMatter, Page, TranscriptSpeakers}

  @max_ms 60_000
  @min_ms 3_000
  # Off each end of a stretch, so a cue's edge doesn't take in the voice
  # either side of it.
  @pad_ms 500
  # Stretches offered to a server that refuses the clip before giving up.
  @attempts 3

  @doc "Whether naming a voice sends a voiceprint: the switch on and a server set."
  def enabled? do
    Settings.get().transcription_voiceprints == true and Transcription.configured?()
  end

  @doc """
  `enabled?/0` for whoever named the voice: only somebody an admin has let
  use meetings and transcription teaches the server a voice (#1206).
  """
  def enabled_for?(user), do: enabled?() and Meetings.allowed?(user)

  @doc """
  The stretches `speaker` speaks in `lines` (each with `:speaker`,
  `:start_ms` and `:end_ms`, in the order spoken), longest first, as
  `{from_ms, to_ms}`: each a run of their lines with nobody else between,
  pulled clear of any other speaker's line that overlaps it, `#{@pad_ms}` ms
  in from each end, and at most 60 s long. Only those of 3 s or more.
  """
  def stretches(lines, speaker) do
    timed = Enum.filter(lines, &is_integer(&1.start_ms))
    others = Enum.reject(timed, &(&1.speaker == speaker))

    timed
    |> Enum.chunk_by(& &1.speaker)
    |> Enum.filter(&(hd(&1).speaker == speaker))
    |> Enum.map(fn run ->
      last = List.last(run)
      from = clear_start(hd(run).start_ms, others)
      to = clear_end(from, max(last.end_ms || last.start_ms, hd(run).start_ms), others)
      {from + @pad_ms, to - @pad_ms}
    end)
    |> Enum.filter(fn {from, to} -> to - from >= @min_ms end)
    |> Enum.sort_by(fn {from, to} -> from - to end)
    |> Enum.map(fn {from, to} -> {from, min(to, from + @max_ms)} end)
  end

  # Past the end of anybody else's line still going when the run starts.
  defp clear_start(from, others) do
    Enum.reduce(others, from, fn o, at ->
      if o.start_ms <= at and is_integer(o.end_ms) and o.end_ms > at, do: o.end_ms, else: at
    end)
  end

  # Up to the start of anybody else's line that begins inside the run.
  defp clear_end(from, to, others) do
    others
    |> Enum.filter(&(&1.start_ms > from and &1.start_ms < to))
    |> Enum.map(& &1.start_ms)
    |> Enum.min(fn -> to end)
  end

  @doc """
  The longest of `stretches/2`: `{:ok, {from_ms, to_ms}}`, `{:error,
  :not_found}` when they have no timed line, `{:error, :too_short}` when
  none is 3 s or more.
  """
  def longest(lines, speaker) do
    case stretches(lines, speaker) do
      [span | _] ->
        {:ok, span}

      [] ->
        if Enum.any?(lines, &(&1.speaker == speaker and is_integer(&1.start_ms))),
          do: {:error, :too_short},
          else: {:error, :not_found}
    end
  end

  ## Naming a voice ------------------------------------------------------------

  @doc """
  `name` was put on a voice in `page`'s transcript: their longest stretch
  goes to the server, in the background. `:ok` when it was started, `:off`
  when there is nothing to do. With `notify: pid`, that process is sent
  `{:put_flash, kind, message}` saying whether it went, and if not why.
  `by:` is who named it, and must be allowed (`enabled_for?/1`).
  """
  def page_named(%Page{} = page, name, opts \\ []) do
    {notify, opts} = Keyword.pop(opts, :notify)
    {by, opts} = Keyword.pop(opts, :by)
    name = String.trim(name)

    if enabled_for?(by) and Speakers.person_label?(name) do
      later(fn ->
        result = from_page(page, name, opts)
        log(result, "page #{page.id}")
        if is_pid(notify), do: send(notify, {:put_flash, flash_kind(result), said(result, name)})
      end)
    else
      :off
    end
  end

  defp flash_kind({:ok, _}), do: :info
  defp flash_kind(_), do: :error

  @doc "Whether `name`'s voiceprint went, as a person reads it."
  def said({:ok, _}, name), do: "#{name}'s voiceprint went to the transcription server."

  def said({:error, reason}, name),
    do: "#{name}'s voiceprint wasn't sent: #{describe(reason)}."

  @doc """
  A meeting capture's voice was confirmed as somebody: their longest
  stretch goes to the server, in the background. `:ok` or `:off`.
  `by:` is who confirmed it, and must be allowed (`enabled_for?/1`).
  """
  def voice_named(%Voice{} = voice, opts \\ []) do
    {by, opts} = Keyword.pop(opts, :by)
    name = Speakers.name(voice)

    if enabled_for?(by) and Speakers.person_label?(name) do
      later(fn ->
        result = from_voice(voice, name, opts)
        log(result, "capture #{voice.capture_id}")

        with {:ok, _} <- result do
          Meetings.record(
            Repo.get!(Capture, voice.capture_id),
            "voice",
            "#{name}'s voice sent to the transcription server as a voiceprint.",
            data: %{"voice_id" => voice.id}
          )
        end
      end)
    else
      :off
    end
  end

  @doc false
  # The work `page_named/3` starts, inline.
  def from_page(%Page{} = page, name, opts \\ []) do
    page = Repo.get!(Page, page.id)

    lines =
      (page.body || "")
      |> TranscriptSpeakers.blocks()
      |> Enum.flat_map(fn block ->
        case Transcript.parse(block, format: "vtt") do
          {:ok, %{lines: lines}} -> lines
          {:error, _} -> []
        end
      end)

    with {:ok, spans} <- spans(lines, name),
         {:ok, path, filename} <- page_recording(page) do
      try do
        send_clips(name, path, filename, spans, opts)
      after
        File.rm(path)
      end
    end
  end

  @doc false
  # The work `voice_named/2` starts, inline.
  def from_voice(%Voice{} = voice, name, opts \\ []) do
    capture = Repo.get!(Capture, voice.capture_id)
    path = Meetings.audio_path(capture)

    lines =
      Repo.all(
        from(u in Utterance,
          where: u.capture_id == ^capture.id,
          order_by: u.position,
          select: %{speaker: u.voice_id, start_ms: u.start_ms, end_ms: u.end_ms}
        )
      )

    if is_nil(path) or not File.regular?(path) do
      {:error, :no_recording}
    else
      with {:ok, spans} <- spans(lines, voice.id) do
        send_clips(name, path, capture.audio_filename || path, spans, opts)
      end
    end
  end

  defp spans(lines, speaker) do
    with {:ok, _} <- longest(lines, speaker),
         do: {:ok, lines |> stretches(speaker) |> Enum.take(@attempts)}
  end

  # The longest first; a clip the server refuses ("Multiple speakers") is
  # followed by the next, and the last refusal is the answer.
  defp send_clips(name, path, filename, [span | rest], opts) do
    case send_clip(name, path, filename, span, opts) do
      {:error, {:refused, _}} when rest != [] -> send_clips(name, path, filename, rest, opts)
      result -> result
    end
  end

  defp send_clip(name, path, filename, {from, to}, opts) do
    with {:ok, clip} <- Relisten.clip(path, filename, from, to) do
      Transcription.add_voiceprint(clip, name, opts)
    end
  end

  # The page's recording, fetched whole from its vault owner's Drive into a
  # file of its own: `{:ok, path, filename}`. The caller removes the file.
  defp page_recording(page) do
    yaml = FrontMatter.yaml(page.front_matter)
    recording = FrontMatter.get(yaml, "recording")
    drive_id = FrontMatter.get(yaml, "recording_drive_id")

    with recording when is_binary(recording) <- recording,
         vault when not is_nil(vault) <- Vaults.for_board(page.board_id),
         {:ok, file} <-
           Recordings.resolve(vault, recording, if(is_binary(drive_id), do: drive_id)) do
      path =
        Path.join(
          System.tmp_dir!(),
          "slipdock-voiceprint-#{System.unique_integer([:positive])}#{Path.extname(recording)}"
        )

      case Drive.download(vault.user_id, file.id, [], File.stream!(path)) do
        {:ok, %{status: 200}} ->
          {:ok, path, recording}

        _ ->
          File.rm(path)
          {:error, "couldn't fetch the recording from Google Drive"}
      end
    else
      # Kept apart from our own reasons: Drive's `:not_found` is the file.
      {:error, reason} -> {:error, {:recording, reason}}
      _ -> {:error, :no_recording}
    end
  end

  defp log({:ok, _}, what),
    do: Logger.info("voiceprint for #{what} sent to the transcription server")

  defp log({:error, reason}, what),
    do: Logger.warning("voiceprint for #{what} not sent: #{describe(reason)}")

  @doc "A reason a voiceprint wasn't sent, as a person reads it."
  def describe(:unsupported), do: "the transcription server doesn't take voiceprints"
  def describe(:not_found), do: "nobody by that name speaks in a timed line"
  def describe(:too_short), do: "their longest stretch is under #{div(@min_ms, 1000)} seconds"
  def describe(:no_recording), do: "there is no recording to cut it from"
  def describe({:recording, :not_found}), do: "the recording isn't in Google Drive"
  def describe({:recording, :not_audio}), do: "the recording isn't audio"

  def describe({:recording, reason}),
    do: "the recording couldn't be fetched from Google Drive (#{reason})"

  def describe({:refused, reason}), do: reason
  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: inspect(reason)

  # In the background, unless the tests ask for it inline (as transcription does).
  defp later(fun) do
    if Keyword.get(Slipdock.Config.get(:transcription, []), :async) == false do
      fun.()
    else
      Task.Supervisor.start_child(Slipdock.TaskSupervisor, fun)
    end

    :ok
  end
end
