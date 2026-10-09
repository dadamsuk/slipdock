defmodule Slipdock.Meetings.Ingest do
  @moduledoc """
  Receiving a meeting (pipeline step 1): what the API, the CLI, MCP and the
  New capture page all go through, so a file one of them refuses is refused
  by every one of them, in the same words.

  In order: is this kind of thing accepted here; is each file within its
  limits; does the transcript parse; does the invite; does a capture of the
  same meeting already exist on the board (G10); then the capture is made,
  with its lines and its recording. Nothing is stored unless every check
  passes, so a malformed file leaves nothing behind.

  `params` (atom keys):

    * `:transcript` — `%{content: text, filename: name}` (or a bare string)
    * `:audio` — `%{path:, filename:, content_type:}`
    * `:findings` — `%{content: json}` (or a bare string): an agent's own
      reading of the meeting, checked like any other (see
      `Slipdock.Meetings.Reader`)
    * `:ics` — an invite's text, for attendees, start and title
    * `:title`, `:started_at` (`DateTime`, ISO 8601 or a date), `:attendees`
      (names and/or emails, as a list or comma-separated)
    * `:format` — the transcript's format, when detection should not guess
    * `:context` — `%{parent: true}` to read the parent board as well
    * `:retention` — how long the recording is kept (`until_committed`,
      `30_days`, `90_days`)
    * `:source` — `upload`, `agent` or `connector`
  """

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.{Meetings, Settings}
  alias Slipdock.Meetings.{Calendar, Limits, Transcript}

  @doc """
  `{:ok, capture}`, `{:existing, capture}` (the same meeting was sent to this
  board before), `{:error, {:invalid, message}}` (a 422: nothing was stored),
  or `{:error, changeset}` (a limit, or the capture itself refused).
  """
  @spec ingest(Board.t(), User.t(), map()) ::
          {:ok, Meetings.Capture.t()}
          | {:existing, Meetings.Capture.t()}
          | {:error, {:invalid, String.t()} | Ecto.Changeset.t()}
  def ingest(%Board{} = board, %User{} = user, params) do
    transcript = content(params[:transcript])
    findings = content(params[:findings])
    audio = params[:audio]

    with :ok <- something_sent(transcript, audio),
         :ok <- accepted(transcript, audio, findings),
         :ok <- within_limits(transcript, audio, findings),
         {:ok, parsed} <- parse_transcript(transcript, params),
         {:ok, invite} <- parse_invite(params[:ics]),
         {:ok, findings_json} <- parse_findings(findings),
         :ok <- not_too_long(parsed),
         {:ok, started_at} <- started_at(params[:started_at], invite) do
      text = transcript && transcript.content
      fingerprint = Meetings.fingerprint(transcript: text, audio: audio && audio.path)

      attrs = %{
        title: title(params[:title], invite, transcript, audio),
        started_at: started_at,
        attendees: attendees(board, params[:attendees], invite),
        fingerprint: fingerprint,
        source: params[:source] || "upload",
        sources: sources(transcript, parsed, audio, findings_json, params),
        context_scope: context_scope(board, params[:context]),
        retention: params[:retention] || "30_days",
        transcript: text,
        transcript_format: parsed && parsed.format
      }

      case Meetings.create_capture(board, user, attrs,
             utterances: (parsed && parsed.lines) || [],
             audio: audio && Map.put_new(audio, :filename, "recording")
           ) do
        # Received: the reading starts (in the background, unless config
        # says otherwise — see `Slipdock.Meetings.Pipeline`).
        {:ok, capture} -> {:ok, Slipdock.Meetings.Pipeline.start(capture)}
        other -> other
      end
    end
  end

  # Upload slots arrive as maps; the API and MCP may send the text itself.
  defp content(nil), do: nil
  defp content(""), do: nil
  defp content(text) when is_binary(text), do: %{content: text, filename: nil}
  defp content(%{content: c} = file) when is_binary(c) and c != "", do: file
  defp content(_), do: nil

  defp something_sent(nil, nil),
    do: invalid("send a recording, a transcript, or both — a capture needs one or the other")

  defp something_sent(_, _), do: :ok

  defp accepted(transcript, audio, findings) do
    settings = Settings.get()

    cond do
      transcript && not settings.meetings_accept_transcripts ->
        invalid("this server does not accept transcripts for meeting capture")

      audio && not settings.meetings_accept_audio ->
        invalid("this server does not accept recordings for meeting capture")

      findings && not settings.meetings_accept_findings ->
        invalid("this server does not accept findings from an agent")

      true ->
        :ok
    end
  end

  defp within_limits(transcript, audio, findings) do
    cond do
      transcript && byte_size(transcript.content) > Limits.max_transcript_bytes() ->
        invalid(
          "the transcript is #{human(byte_size(transcript.content))}; the most this server " <>
            "takes is #{human(Limits.max_transcript_bytes())}"
        )

      findings && byte_size(findings.content) > Limits.max_findings_bytes() ->
        invalid("the findings file is over #{human(Limits.max_findings_bytes())}")

      audio && audio_size(audio) > Limits.max_audio_bytes() ->
        invalid(
          "the recording is #{human(audio_size(audio))}; the most this server takes is " <>
            human(Limits.max_audio_bytes())
        )

      audio && not Limits.audio_type?(audio) ->
        invalid(
          "#{audio[:filename] || "the recording"} is not an audio format this server takes " <>
            "(#{Enum.join(Limits.audio_extensions(), ", ")})"
        )

      true ->
        :ok
    end
  end

  defp audio_size(%{size: size}) when is_integer(size), do: size
  defp audio_size(%{path: path}), do: File.stat!(path).size

  defp parse_transcript(nil, _params), do: {:ok, nil}

  defp parse_transcript(%{content: content} = file, params) do
    case Transcript.parse(content, format: params[:format], filename: file[:filename]) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, message} -> invalid(message)
    end
  end

  defp parse_invite(nil), do: {:ok, nil}
  defp parse_invite(""), do: {:ok, nil}
  defp parse_invite(%{content: text}), do: parse_invite(text)

  defp parse_invite(text) when is_binary(text) do
    case Calendar.parse(text) do
      {:ok, invite} -> {:ok, invite}
      {:error, message} -> invalid(message)
    end
  end

  defp parse_findings(nil), do: {:ok, nil}

  defp parse_findings(%{content: text}) do
    case Jason.decode(text) do
      {:ok, %{"findings" => list} = doc} when is_list(list) -> {:ok, doc}
      {:ok, list} when is_list(list) -> {:ok, %{"findings" => list}}
      {:ok, _} -> invalid("the findings file should be {\"findings\": [...]} (see the schema)")
      {:error, _} -> invalid("the findings file is not valid JSON")
    end
  end

  # A transcript's own times say how long the meeting ran.
  defp not_too_long(nil), do: :ok

  defp not_too_long(%{lines: lines}) do
    last = lines |> Enum.map(&(&1.end_ms || &1.start_ms || 0)) |> Enum.max(fn -> 0 end)
    max_ms = Limits.longest_meeting_minutes() * 60_000

    if last > max_ms,
      do:
        invalid(
          "the meeting runs #{div(last, 60_000)} minutes; the longest this server reads is " <>
            "#{Limits.longest_meeting_minutes()} minutes"
        ),
      else: :ok
  end

  defp started_at(nil, %{started_at: %DateTime{} = at}), do: {:ok, at}
  defp started_at(nil, _), do: {:ok, nil}
  defp started_at("", invite), do: started_at(nil, invite)
  defp started_at(%DateTime{} = at, _), do: {:ok, DateTime.truncate(at, :second)}

  defp started_at(value, _) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} ->
        {:ok, DateTime.truncate(at, :second)}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} ->
            {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)}

          _ ->
            case Date.from_iso8601(value) do
              {:ok, date} -> {:ok, DateTime.new!(date, ~T[09:00:00])}
              _ -> invalid("“#{value}” is not a date and time (use 2026-10-07T10:00)")
            end
        end
    end
  end

  defp started_at(_, _), do: invalid("the meeting's start should be a date and time")

  defp title(title, invite, transcript, audio) do
    case title && String.trim(title) do
      t when is_binary(t) and t != "" ->
        t

      _ ->
        (invite && invite.title) ||
          filename_title(transcript && transcript[:filename]) ||
          filename_title(audio && audio[:filename]) ||
          "Meeting on #{Date.utc_today()}"
    end
  end

  defp filename_title(nil), do: nil

  defp filename_title(name) do
    case name |> Path.rootname() |> String.replace(~r/[_-]+/, " ") |> String.trim() do
      "" -> nil
      t -> t
    end
  end

  @doc """
  The attendees, matched to the board's members where a name or an address
  says who they are: `%{"name", "email", "user_id"}`.
  """
  def attendees(board, typed, invite) do
    members = Slipdock.Wiki.Links.members(board)

    typed =
      case typed do
        nil -> []
        list when is_list(list) -> list
        text when is_binary(text) -> String.split(text, [",", ";", "\n"])
      end
      |> Enum.map(&attendee/1)
      |> Enum.reject(&is_nil/1)

    (typed ++ ((invite && invite.attendees) || []))
    |> Enum.map(&match_member(&1, members))
    |> Enum.uniq_by(&(&1["user_id"] || &1["email"] || String.downcase(&1["name"] || "")))
  end

  defp attendee(%{} = map) do
    map = Map.new(map, fn {k, v} -> {to_string(k), v} end)
    if map["name"] || map["email"], do: %{name: map["name"], email: map["email"]}
  end

  defp attendee(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> nil
      # "Sam Smith <sam@example.com>"
      match = Regex.run(~r/^(.*?)\s*<([^>]+@[^>]+)>$/, text) -> named(match)
      String.contains?(text, "@") -> %{name: nil, email: String.downcase(text)}
      true -> %{name: text, email: nil}
    end
  end

  defp attendee(_), do: nil

  defp named([_, name, email]),
    do: %{name: if(name == "", do: nil, else: name), email: String.downcase(email)}

  defp match_member(%{name: name, email: email}, members) do
    member =
      (email && Enum.find(members, &(String.downcase(&1.email) == email))) ||
        (name && Enum.find(members, &same_name?(&1, name)))

    %{
      "name" => name || (member && member.name),
      "email" => email || (member && member.email),
      "user_id" => member && member.id
    }
  end

  # "Sam" is Sam Smith when nobody else on the board is a Sam.
  defp same_name?(%{name: nil}, _), do: false

  defp same_name?(%{name: member}, name) do
    member = String.downcase(member)
    name = String.downcase(String.trim(name))
    member == name or hd(String.split(member)) == name
  end

  defp sources(transcript, parsed, audio, findings, params) do
    %{
      "transcript" =>
        transcript &&
          %{
            "filename" => transcript[:filename],
            "format" => parsed.format,
            "bytes" => byte_size(transcript.content),
            "lines" => length(parsed.lines)
          },
      "audio" =>
        audio &&
          %{
            "filename" => audio[:filename],
            "content_type" => audio[:content_type],
            "bytes" => audio_size(audio)
          },
      "findings" =>
        findings && %{"count" => length(findings["findings"]), "document" => findings},
      "ics" => params[:ics] not in [nil, ""],
      "via" => params[:via] && to_string(params[:via])
    }
    |> Map.reject(fn {_, v} -> v in [nil, false] end)
  end

  # This board and its wiki always; the parent only when asked, and only when
  # there is one.
  defp context_scope(board, context) do
    parent? =
      board.parent_card_id != nil and
        (context || %{})
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.get("parent")
        |> truthy?()

    %{"board" => true, "wiki" => true, "parent" => parent?}
  end

  defp truthy?(v), do: v in [true, "true", "1", "on", 1]

  defp invalid(message), do: {:error, {:invalid, message}}

  defp human(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp human(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)} KB"
  defp human(bytes), do: "#{bytes} bytes"
end
