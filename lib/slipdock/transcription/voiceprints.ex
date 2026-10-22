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
      the longest of them, cut to at most 60 s; under 3 s is too little to
      send.
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

  @doc "Whether naming a voice sends a voiceprint: the switch on and a server set."
  def enabled? do
    Settings.get().transcription_voiceprints == true and Transcription.configured?()
  end

  @doc """
  The longest stretch `speaker` speaks in `lines` (each with `:speaker`,
  `:start_ms` and `:end_ms`, in the order spoken): `{:ok, {from_ms,
  to_ms}}`, at most 60 s long. `{:error, :not_found}` when they have no
  timed line, `{:error, :too_short}` when their longest is under 3 s.
  """
  def longest(lines, speaker) do
    lines
    |> Enum.chunk_by(& &1.speaker)
    |> Enum.filter(&(hd(&1).speaker == speaker))
    |> Enum.flat_map(fn run ->
      case Enum.filter(run, &is_integer(&1.start_ms)) do
        [] ->
          []

        timed ->
          from = hd(timed).start_ms
          last = List.last(timed)
          [{from, max(last.end_ms || last.start_ms, from)}]
      end
    end)
    |> Enum.max_by(fn {from, to} -> to - from end, fn -> nil end)
    |> case do
      nil -> {:error, :not_found}
      {from, to} when to - from < @min_ms -> {:error, :too_short}
      {from, to} -> {:ok, {from, min(to, from + @max_ms)}}
    end
  end

  ## Naming a voice ------------------------------------------------------------

  @doc """
  `name` was put on a voice in `page`'s transcript: their longest stretch
  goes to the server, in the background. `:ok` when it was started, `:off`
  when there is nothing to do.
  """
  def page_named(%Page{} = page, name, opts \\ []) do
    if enabled?() and Speakers.person_label?(name),
      do: later(fn -> log(from_page(page, String.trim(name), opts), "page #{page.id}") end),
      else: :off
  end

  @doc """
  A meeting capture's voice was confirmed as somebody: their longest
  stretch goes to the server, in the background. `:ok` or `:off`.
  """
  def voice_named(%Voice{} = voice, opts \\ []) do
    name = Speakers.name(voice)

    if enabled?() and Speakers.person_label?(name) do
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

    with {:ok, span} <- longest(lines, name),
         {:ok, path, filename} <- page_recording(page) do
      try do
        send_clip(name, path, filename, span, opts)
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
      with {:ok, span} <- longest(lines, voice.id) do
        send_clip(name, path, capture.audio_filename || path, span, opts)
      end
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
      {:error, _} = error -> error
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
