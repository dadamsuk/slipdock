defmodule SlipdockWeb.Meetings.IngestAPITest do
  @moduledoc """
  Sending a meeting (#532): `POST /api/boards/:board/captures` with a file or
  the text, every refusal a 422 that names the problem and stores nothing,
  the meeting sent twice found rather than doubled, and `GET /api/captures/:id`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Repo, Settings}
  alias Slipdock.Meetings.Capture

  @dir Path.expand("../../fixtures/meetings", __DIR__)

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing", "code" => "PL"}, owner: user)
    %{board: board}
  end

  defp upload(name, type \\ "text/plain"),
    do: %Plug.Upload{path: Path.join(@dir, name), filename: name, content_type: type}

  defp audio(bytes \\ "fake audio") do
    path = Path.join(System.tmp_dir!(), "api-#{System.unique_integer([:positive])}.mp3")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "call.mp3", content_type: "audio/mpeg"}
  end

  defp count, do: Repo.aggregate(Capture, :count)

  test "a WebVTT file makes a capture with its lines, attendees and link", %{
    conn: conn,
    board: board,
    user: user
  } do
    sam = user_fixture("sam@example.com")
    share_fixture(board, [sam], "write")

    body =
      conn
      |> post(~p"/api/boards/#{board.code}/captures", %{
        "transcript" => upload("pricing.vtt"),
        "title" => "Pricing sync",
        "when" => "2026-10-07T10:00:00Z",
        "attendees" => "Priya, #{sam.email}"
      })
      |> json_response(201)

    assert %{"existing" => false, "capture" => capture} = body
    assert capture["title"] == "Pricing sync"
    assert capture["state"] == "reading"
    assert capture["started_at"] == "2026-10-07T10:00:00Z"
    assert capture["sent_by"] == user.email
    assert capture["url"] == "http://www.example.com/boards/#{board.id}/meetings/#{capture["id"]}"
    assert capture["inputs"] == %{"transcript" => true, "audio" => false, "findings" => false}
    assert capture["counts"]["lines"] == 3
    assert [%{"id" => "L1", "speaker" => "Priya", "start_ms" => 0} | _] = capture["lines"]

    assert [%{"name" => "Priya", "user_id" => nil}, %{"email" => sam_email, "user_id" => sam_id}] =
             capture["attendees"]

    assert sam_email == sam.email and sam_id == sam.id
  end

  test "the transcript can be sent as text in JSON, with an invite for the rest", %{
    conn: conn,
    board: board
  } do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/boards/#{board.id}/captures",
        Jason.encode!(%{
          "transcript" => File.read!(Path.join(@dir, "pricing.txt")),
          "ics" => File.read!(Path.join(@dir, "pricing.ics"))
        })
      )
      |> json_response(201)

    capture = body["capture"]
    assert capture["title"] == "Pricing sync, weekly"
    assert capture["started_at"] == "2026-10-07T10:00:00Z"
    assert length(capture["attendees"]) == 3
  end

  test "the same meeting sent twice is found, not doubled (G10)", %{conn: conn, board: board} do
    first =
      conn
      |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => upload("pricing.srt")})
      |> json_response(201)

    again =
      conn
      |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => upload("pricing.srt")})
      |> json_response(200)

    assert again["existing"] == true
    assert again["capture"]["id"] == first["capture"]["id"]
    assert count() == 1
  end

  test "a recording alone is stored, and named after its file", %{conn: conn, board: board} do
    body =
      conn
      |> post(~p"/api/boards/#{board.id}/captures", %{"audio" => audio()})
      |> json_response(201)

    assert body["capture"]["title"] == "call"
    assert body["capture"]["inputs"]["audio"] == true
    assert Repo.get!(Capture, body["capture"]["id"]).audio_size == 10
  end

  describe "refusals: a 422 naming the problem, and nothing stored" do
    for {name, params, message} <- [
          {"nothing sent", %{"title" => "x"}, "send a recording, a transcript, or both"},
          {"an empty transcript", %{"transcript" => "   "}, "the transcript is empty"},
          {"a malformed export",
           %{"transcript" => "{\"sentences\": [1,", "format" => "fireflies"},
           "the JSON is not valid"},
          {"an unknown format", %{"transcript" => "hi", "format" => "docx"},
           ~s("docx" is not a transcript format)},
          {"a bad start", %{"transcript" => "Sam: hi", "when" => "next tuesday"},
           "is not a date and time"},
          {"a broken invite", %{"transcript" => "Sam: hi", "ics" => "BEGIN:VCALENDAR"},
           "the invite has no event in it"},
          {"broken findings", %{"transcript" => "Sam: hi", "findings" => "{nope"},
           "the findings file is not valid JSON"},
          {"findings of the wrong shape", %{"transcript" => "Sam: hi", "findings" => ~s({"a":1})},
           "the findings file should be"}
        ] do
      test name, %{conn: conn, board: board} do
        body =
          conn
          |> post(~p"/api/boards/#{board.id}/captures", unquote(Macro.escape(params)))
          |> json_response(422)

        assert body["error"] =~ unquote(message)
        assert count() == 0
      end
    end

    test "a file that is not audio", %{conn: conn, board: board} do
      bad = %Plug.Upload{
        path: Path.join(@dir, "pricing.txt"),
        filename: "notes.pdf",
        content_type: "application/pdf"
      }

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/captures", %{"audio" => bad})
        |> json_response(422)

      assert body["error"] =~ "notes.pdf is not an audio format this server takes"
      assert count() == 0
    end

    test "a transcript over the size limit", %{conn: conn, board: board} do
      Slipdock.TestConfig.merge(:meetings, max_transcript_bytes: 20)

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => upload("pricing.vtt")})
        |> json_response(422)

      assert body["error"] =~ "the most this server takes is 20 bytes"
      assert count() == 0
    end

    test "a meeting longer than the longest read", %{conn: conn, board: board} do
      Slipdock.TestConfig.merge(:meetings, longest_meeting_minutes: 1)

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/captures", %{
          "transcript" => "[00:00:00] Sam: start\n[01:30:00] Sam: still going"
        })
        |> json_response(422)

      assert body["error"] =~
               "the meeting runs 90 minutes; the longest this server reads is 1 minutes"

      assert count() == 0
    end

    test "a kind of input the admin switched off", %{conn: conn, board: board} do
      {:ok, _} = Settings.update(%{"meetings_accept_transcripts" => false})

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => "Sam: hi"})
        |> json_response(422)

      assert body["error"] == "this server does not accept transcripts for meeting capture"

      {:ok, _} =
        Settings.update(%{
          "meetings_accept_transcripts" => true,
          "meetings_accept_audio" => false
        })

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/captures", %{"audio" => audio()})
        |> json_response(422)

      assert body["error"] == "this server does not accept recordings for meeting capture"
      assert count() == 0
    end

    test "meeting mode off", %{conn: conn, board: board} do
      {:ok, _} = Settings.update(%{"meetings_enabled" => false})

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => "Sam: hi"})
        |> json_response(404)

      assert body["error"] == "meeting mode is off on this server"
      assert count() == 0
    end

    test "a board the caller may only read", %{board: board} do
      reader = user_fixture("reader@example.com")
      share_fixture(board, [reader], "read")

      conn_as(reader)
      |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => "Sam: hi"})
      |> json_response(403)

      assert count() == 0
    end

    test "a read-only token", %{board: board, user: user} do
      {token, _} = Slipdock.Accounts.create_api_token(user, "ro", scope: "read")

      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/boards/#{board.id}/captures", %{"transcript" => "Sam: hi"})
      |> json_response(403)

      assert count() == 0
    end
  end

  test "GET /api/meetings/findings-schema serves the published format", %{conn: conn} do
    body = conn |> get(~p"/api/meetings/findings-schema") |> json_response(200)
    assert body["title"] == "Meeting findings"
    assert body["properties"]["findings"]["items"]["required"] == ["kind", "title", "evidence"]
  end

  describe "reading them back" do
    test "GET /api/captures/:id for somebody who can read the board", %{
      conn: conn,
      board: board,
      user: user
    } do
      capture = capture_fixture(board, user)
      body = conn |> get(~p"/api/captures/#{capture.id}") |> json_response(200)
      assert body["capture"]["id"] == capture.id
      assert body["capture"]["counts"]["lines"] == 4
      assert [%{"kind" => "received"}] = body["capture"]["record"]
    end

    test "open questions counted leave out those on a finding left out", %{
      conn: conn,
      board: board,
      user: user
    } do
      capture = reviewed_capture(board, user, [action_finding("Sammy")])
      body = conn |> get(~p"/api/captures/#{capture.id}") |> json_response(200)
      assert body["capture"]["counts"]["open_questions"] == 1

      [finding] =
        Repo.all(from(f in Slipdock.Meetings.Finding, where: f.capture_id == ^capture.id))

      {:ok, _} = Slipdock.Meetings.Review.include(finding, false, user)

      body = conn |> get(~p"/api/captures/#{capture.id}") |> json_response(200)
      assert body["capture"]["counts"]["open_questions"] == 0
      assert body["capture"]["state"] == "ready"
      assert [%{"status" => "open"}] = body["capture"]["questions"]
    end

    test "a capture on a board the caller cannot read is a 404", %{board: board, user: user} do
      capture = capture_fixture(board, user)
      stranger = user_fixture("stranger@example.com")
      conn_as(stranger) |> get(~p"/api/captures/#{capture.id}") |> json_response(404)
      conn_as(stranger) |> get(~p"/api/captures/nope") |> json_response(404)
    end

    test "GET /api/boards/:board/captures lists them newest first", %{
      conn: conn,
      board: board,
      user: user
    } do
      a = capture_fixture(board, user, %{title: "First"})
      b = capture_fixture(board, user, %{title: "Second"})

      Repo.update_all(from(c in Capture, where: c.id == ^a.id),
        set: [inserted_at: ~U[2026-01-01 00:00:00Z]]
      )

      body = conn |> get(~p"/api/boards/#{board.id}/captures") |> json_response(200)
      assert Enum.map(body["captures"], & &1["id"]) == [b.id, a.id]
      assert Meetings.get_capture(a.id)
    end
  end
end
