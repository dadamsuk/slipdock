defmodule Slipdock.Transcription.VoiceprintsTest do
  @moduledoc """
  Naming a voice teaches the transcription server it (#1201): the longest
  stretch of that person speaking is cut from the recording and sent to
  `POST /v1/voiceprints` under the name, from a meeting capture's *Who said
  what* and from a wiki page's transcript — only with the admin's switch on,
  a server that takes voiceprints, and a person's name.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures
  import Slipdock.GoogleStub

  alias Slipdock.{Meetings, Repo, Settings, Transcription, Vaults, Wiki}
  alias Slipdock.Meetings.{Event, Speakers, Voice}
  alias Slipdock.Transcription.Voiceprints

  @url "https://transcribe.example:8765"
  @rate 16_000
  @status %{"version" => "2.5.0", "api_version" => "1.1.0", "capabilities" => ["voiceprints"]}

  # A real WAV, 16 kHz mono 16-bit, `seconds` long; every byte of second n
  # is n, so a clip shows where in the recording it was cut from.
  defp wav(seconds) do
    data = for n <- 0..(seconds - 1), into: <<>>, do: :binary.copy(<<n>>, @rate * 2)

    <<"RIFF", 36 + byte_size(data)::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, @rate::little-32, @rate * 2::little-32, 2::little-16, 16::little-16, "data",
      byte_size(data)::little-32, data::binary>>
  end

  # The server: answers GET /v1/status with `status` and every POST with
  # `answer`, and tells the test what each POST carried.
  defp serve(status \\ @status, answer \\ {201, %{"id" => "vp_1"}}) do
    test = self()

    Req.Test.stub(Transcription, fn conn ->
      if conn.request_path == "/v1/status" do
        send(test, {:status, conn.req_headers})
        Req.Test.json(conn, status)
      else
        conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))

        send(
          test,
          {:voiceprint, conn.request_path, conn.params["name"],
           File.read!(conn.params["file"].path), conn.req_headers}
        )

        {code, body} = answer
        conn |> Plug.Conn.put_status(code) |> Req.Test.json(body)
      end
    end)
  end

  # Refuses the first `n` clips the way Manuel2 does, then takes the next.
  defp refuse_then_take(n) do
    test = self()
    seen = :counters.new(1, [])

    Req.Test.stub(Transcription, fn conn ->
      if conn.request_path == "/v1/status" do
        Req.Test.json(conn, @status)
      else
        conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))

        send(
          test,
          {:voiceprint, conn.request_path, conn.params["name"],
           File.read!(conn.params["file"].path), conn.req_headers}
        )

        :counters.add(seen, 1, 1)
        count = :counters.get(seen, 1)

        if count <= n,
          do:
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{"error" => %{"message" => "Multiple speakers"}}),
          else: Req.Test.json(conn, %{"id" => "vp_#{count}"})
      end
    end)
  end

  defp on(extra \\ %{}) do
    {:ok, _} =
      Settings.update(
        Map.merge(
          %{
            "transcription_server_url" => @url,
            "transcription_server_token" => "k3y",
            "transcription_voiceprints" => true
          },
          extra
        )
      )
  end

  # The audio a clip holds, past its 44-byte header.
  defp clip_data(<<"RIFF", _::binary-size(40), data::binary>>), do: data

  defp events(capture),
    do: Repo.all(from(e in Event, where: e.capture_id == ^capture.id))

  defp line(speaker, from, to), do: %{speaker: speaker, start_ms: from, end_ms: to}

  describe "the longest stretch" do
    test "is the longest run of lines with nobody else between" do
      lines = [
        line("Sam", 0, 5_000),
        line("Ollie", 5_000, 6_000),
        line("Sam", 6_000, 9_000),
        line("Sam", 9_500, 14_000),
        line("Ollie", 14_000, 30_000)
      ]

      # Half a second in from each end.
      assert Voiceprints.longest(lines, "Sam") == {:ok, {6_500, 13_500}}
      assert Voiceprints.longest(lines, "Ollie") == {:ok, {14_500, 29_500}}
    end

    test "is cut to a minute" do
      assert Voiceprints.longest([line("Sam", 10_000, 200_000)], "Sam") ==
               {:ok, {10_500, 70_500}}
    end

    test "keeps clear of somebody else's line that overlaps it" do
      lines = [
        line("Ollie", 0, 10_500),
        line("Sam", 10_000, 20_000),
        line("Ollie", 19_000, 25_000)
      ]

      # From the end of Ollie's first line to the start of his second.
      assert Voiceprints.longest(lines, "Sam") == {:ok, {11_000, 18_500}}
    end

    test "all of them, longest first, only those long enough" do
      lines = [
        line("Sam", 0, 5_000),
        line("Ollie", 5_000, 6_000),
        line("Sam", 6_000, 20_000),
        line("Ollie", 20_000, 21_000),
        line("Sam", 21_000, 24_000),
        line("Ollie", 24_000, 25_000),
        line("Sam", 25_000, 33_000)
      ]

      assert Voiceprints.stretches(lines, "Sam") ==
               [{6_500, 19_500}, {25_500, 32_500}, {500, 4_500}]
    end

    test "under three seconds is too short, and nobody there is not found" do
      # 3.9 s is under three once half a second comes off each end.
      lines = [line("Sam", 0, 3_900), line("Ollie", 3_900, 9_000)]

      assert Voiceprints.longest(lines, "Sam") == {:error, :too_short}
      assert Voiceprints.longest(lines, "Priya") == {:error, :not_found}
      assert Voiceprints.longest([], "Sam") == {:error, :not_found}
    end

    test "untimed lines don't count, and a line with no end runs to its start" do
      lines = [
        %{speaker: "Sam", start_ms: nil, end_ms: nil},
        line("Ollie", 0, 1_000),
        %{speaker: "Sam", start_ms: nil, end_ms: nil},
        line("Sam", 1_000, 5_000),
        %{speaker: "Sam", start_ms: 6_000, end_ms: nil}
      ]

      assert Voiceprints.longest(lines, "Sam") == {:ok, {1_500, 5_500}}

      assert Voiceprints.longest([%{speaker: "Sam", start_ms: nil, end_ms: nil}], "Sam") ==
               {:error, :not_found}
    end
  end

  describe "sending one" do
    test "posts the clip and the name with the token" do
      serve()

      assert {:ok, %{"id" => "vp_1"}} =
               Transcription.add_voiceprint("CLIP", "Sam Smith", url: @url, token: "k3y")

      assert_received {:voiceprint, "/v1/voiceprints", "Sam Smith", "CLIP", headers}
      assert {"authorization", "Bearer k3y"} in headers
    end

    test "a server that doesn't list voiceprints is not sent one" do
      serve(%{@status | "capabilities" => ["diarization"]})

      assert Transcription.add_voiceprint("CLIP", "Sam", url: @url) == {:error, :unsupported}
      assert_received {:status, _}
      refute_received {:voiceprint, _, _, _, _}
    end

    test "a refusal is put in words" do
      serve(@status, {422, %{"error" => %{"code" => "too_short", "message" => "need 5 s"}}})

      assert {:error, {:refused, "the transcription server said 422 too_short: need 5 s"}} =
               Transcription.add_voiceprint("CLIP", "Sam", url: @url)
    end

    test "with no server there is nothing to send to" do
      assert {:error, "no transcription server is set up"} =
               Transcription.add_voiceprint("CLIP", "Sam")
    end
  end

  describe "naming a voice in a meeting capture" do
    setup do
      meetings_on()
      owner = user_fixture("owner@example.com")
      board = board_fixture(%{"name" => "Pricing"}, owner: owner)
      path = Path.join(System.tmp_dir!(), "m-#{System.unique_integer([:positive])}.wav")
      File.write!(path, wav(24))
      on_exit(fn -> File.rm(path) end)

      {:ok, capture} =
        Meetings.create_capture(
          board,
          owner,
          %{title: "Call", fingerprint: Meetings.fingerprint(audio: path)},
          audio: %{path: path, filename: "call.wav"},
          utterances: [
            %{speaker: "Voice A", text: "Hello.", start_ms: 0, end_ms: 2_000},
            %{speaker: "Voice B", text: "Hi.", start_ms: 2_000, end_ms: 4_000},
            %{speaker: "Voice A", text: "So, the plan.", start_ms: 4_000, end_ms: 9_000},
            %{speaker: "Voice A", text: "And then.", start_ms: 9_000, end_ms: 12_000},
            %{speaker: "Voice B", text: "Right.", start_ms: 12_000, end_ms: 16_000},
            %{speaker: "Voice A", text: "Next.", start_ms: 16_000, end_ms: 20_000},
            %{speaker: "Voice B", text: "Fine.", start_ms: 20_000, end_ms: 24_000}
          ]
        )

      {:ok, _} = Speakers.diarise(capture)
      voice = Repo.get_by!(Voice, capture_id: capture.id, label: "Voice A")
      %{owner: owner, capture: capture, voice: voice}
    end

    test "sends their longest stretch under the name, and the capture records it", ctx do
      on()
      serve()

      assert {:ok, _} = Speakers.reassign(ctx.voice, %{"name" => "Sam Smith"}, ctx.owner)

      assert_received {:voiceprint, "/v1/voiceprints", "Sam Smith", clip, _}
      data = clip_data(clip)
      # 4.5 s to 11.5 s: seven seconds, from inside second 4 to inside 11.
      assert byte_size(data) == 7 * @rate * 2
      assert :binary.first(data) == 4 and :binary.last(data) == 11

      assert Enum.any?(
               events(ctx.capture),
               &(&1.message ==
                   "Sam Smith's voice sent to the transcription server as a voiceprint.")
             )
    end

    test "a clip the server refuses is followed by the next-longest", ctx do
      on()
      refuse_then_take(1)

      assert {:ok, %{"id" => "vp_2"}} = Voiceprints.from_voice(ctx.voice, "Sam Smith")

      assert_received {:voiceprint, _, "Sam Smith", first, _}
      assert_received {:voiceprint, _, "Sam Smith", second, _}
      # 4.5–11.5 s refused, then 16.5–19.5 s; 0.5–1.5 s is too short to offer.
      assert byte_size(clip_data(first)) == 7 * @rate * 2
      assert byte_size(clip_data(second)) == 3 * @rate * 2
      assert :binary.first(clip_data(second)) == 16 and :binary.last(clip_data(second)) == 19
      refute_received {:voiceprint, _, _, _, _}
    end

    test "when every stretch is refused, the last refusal is the answer", ctx do
      on()
      refuse_then_take(99)

      assert {:error, {:refused, "the transcription server said 422: Multiple speakers"}} =
               Voiceprints.from_voice(ctx.voice, "Sam Smith")

      # Both stretches offered, no more.
      assert_received {:voiceprint, _, _, _, _}
      assert_received {:voiceprint, _, _, _, _}
      refute_received {:voiceprint, _, _, _, _}

      assert Voiceprints.describe({:refused, "Multiple speakers"}) == "Multiple speakers"
    end

    test "nothing is sent while the switch is off", ctx do
      on(%{"transcription_voiceprints" => false})
      serve()

      assert {:ok, _} = Speakers.reassign(ctx.voice, %{"name" => "Sam Smith"}, ctx.owner)
      assert Voiceprints.voice_named(ctx.voice) == :off
      refute_received {:status, _}
      refute_received {:voiceprint, _, _, _, _}
    end

    test "a placeholder name teaches nothing", ctx do
      on()
      serve()

      assert {:ok, _} = Speakers.reassign(ctx.voice, %{"name" => "Speaker 3"}, ctx.owner)
      refute_received {:voiceprint, _, _, _, _}
    end

    test "a server that doesn't take voiceprints is only asked its status", ctx do
      on()
      serve(%{@status | "capabilities" => []})

      assert {:ok, voice} = Speakers.reassign(ctx.voice, %{"name" => "Sam Smith"}, ctx.owner)
      assert voice.name == "Sam Smith"
      assert_received {:status, _}
      refute_received {:voiceprint, _, _, _, _}
      refute Enum.any?(events(ctx.capture), &(&1.message =~ "voiceprint"))
    end

    test "with the recording gone there is nothing to cut it from", ctx do
      on()
      File.rm!(Meetings.audio_path(ctx.capture))

      assert Voiceprints.from_voice(ctx.voice, "Sam Smith") == {:error, :no_recording}
    end
  end

  describe "naming a voice in a wiki page's transcript" do
    setup do
      user = user_fixture("pages@example.com")
      board = board_fixture(%{"name" => "Notes"}, owner: user)
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: board})
      vault |> Ecto.Changeset.change(recordings_folder: "Rec") |> Repo.update!()
      connect!(user)

      drive!([
        %{
          "id" => "fold",
          "name" => "Rec",
          "mimeType" => "application/vnd.google-apps.folder",
          "parents" => ["root"]
        },
        %{
          "id" => "aud",
          "name" => "m.wav",
          "mimeType" => "audio/wav",
          "parents" => ["fold"],
          content: wav(12)
        }
      ])

      body = """
      ## Transcript

      ```vtt
      WEBVTT

      00:00:00.000 --> 00:00:01.000
      <v Speaker 1>Hi.

      00:00:01.000 --> 00:00:02.000
      <v Speaker 2>Hello.

      00:00:02.000 --> 00:00:05.000
      Speaker 1: Shall we start?

      00:00:05.000 --> 00:00:08.000
      <v Speaker 1>There is a lot.

      00:00:08.000 --> 00:00:12.000
      <v Speaker 2>Go on.
      ```
      """

      page =
        page_fixture(board, %{
          "title" => "Standup",
          "front_matter" => "---\nrecording: gdrive:Rec/m.wav\n---\n\n",
          "body" => body
        })

      %{user: user, page: page}
    end

    test "renaming a speaker sends their longest stretch from the Drive recording", ctx do
      on()
      serve()

      assert {:ok, _} = Wiki.rename_speaker(ctx.page, "Speaker 1", "Priya Nair", user: ctx.user)

      assert_received {:voiceprint, "/v1/voiceprints", "Priya Nair", clip, _}
      data = clip_data(clip)
      # 2.5 s to 7.5 s, two cues of theirs with nobody between.
      assert byte_size(data) == 5 * @rate * 2
      assert :binary.first(data) == 2 and :binary.last(data) == 7
    end

    test "whoever asked is told it went", ctx do
      on()
      serve()

      assert {:ok, _} =
               Wiki.rename_speaker(ctx.page, "Speaker 1", " Priya Nair ",
                 user: ctx.user,
                 notify: self()
               )

      assert_received {:voiceprint, "/v1/voiceprints", "Priya Nair", _, _}

      assert_received {:put_flash, :info,
                       "Priya Nair's voiceprint went to the transcription server."}
    end

    test "whoever asked is told why it didn't go", ctx do
      on()
      serve(%{@status | "capabilities" => []})

      assert {:ok, _} =
               Wiki.rename_speaker(ctx.page, "Speaker 1", "Priya Nair",
                 user: ctx.user,
                 notify: self()
               )

      assert_received {:put_flash, :error,
                       "Priya Nair's voiceprint wasn't sent: the transcription server doesn't take voiceprints."}

      refute_received {:voiceprint, _, _, _, _}
    end

    test "a recording that isn't WAV needs ffmpeg to be cut, and says so", ctx do
      on()
      serve()
      Slipdock.TestConfig.merge(:meetings, ffmpeg: false)

      drive!([
        %{
          "id" => "fold",
          "name" => "Rec",
          "mimeType" => "application/vnd.google-apps.folder",
          "parents" => ["root"]
        },
        %{
          "id" => "m4a",
          "name" => "m.m4a",
          "mimeType" => "audio/mp4",
          "parents" => ["fold"],
          content: "not really an m4a"
        }
      ])

      {:ok, page} =
        Wiki.update_page(
          ctx.page,
          %{"front_matter" => "---\nrecording: gdrive:Rec/m.m4a\n---\n\n"},
          user: ctx.user
        )

      assert {:ok, _} =
               Wiki.rename_speaker(page, "Speaker 1", "Priya Nair",
                 user: ctx.user,
                 notify: self()
               )

      assert_received {:put_flash, :error,
                       "Priya Nair's voiceprint wasn't sent: only WAV recordings can be cut without ffmpeg."}

      refute_received {:voiceprint, _, _, _, _}
    end

    test "a recording gone from Drive says so, not that nobody speaks", ctx do
      on()
      serve()
      drive!([])

      assert Voiceprints.from_page(ctx.page, "Speaker 1") == {:error, {:recording, :not_found}}

      assert Voiceprints.describe({:recording, :not_found}) ==
               "the recording isn't in Google Drive"

      refute_received {:voiceprint, _, _, _, _}
    end

    test "nothing is fetched or sent while the switch is off", ctx do
      serve()

      assert {:ok, _} = Wiki.rename_speaker(ctx.page, "Speaker 1", "Priya Nair", user: ctx.user)
      refute_received {:drive, _, _, _}
      refute_received {:voiceprint, _, _, _, _}
    end

    test "a page with no recording has nothing to cut it from", ctx do
      on()
      {:ok, page} = Wiki.update_page(ctx.page, %{"front_matter" => ""}, user: ctx.user)

      assert Voiceprints.from_page(page, "Speaker 1") == {:error, :no_recording}
    end

    test "a name nobody speaks under is not found, and nothing is fetched", ctx do
      on()

      assert Voiceprints.from_page(ctx.page, "Nobody") == {:error, :not_found}
      refute_received {:drive, _, _, _}
    end
  end
end
