defmodule SlipdockCLI.MeetingsTest do
  @moduledoc "`slipdock meetings` and the meeting settings under `slipdock admin`."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Admin, FakeServer, Meetings}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-meetings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  test "meetings says it is on and where it shows" do
    serve([
      {200,
       ~s({"meetings":{"enabled":true,"visibility":"used_only","hideable":true,"hidden":true}})}
    ])

    out = capture_io(fn -> Meetings.run("meetings", [], []) end)
    assert_received {:request, "GET", "/api/meetings", _}
    assert out =~ "Meeting mode: on"
    assert out =~ "on boards that have had a capture"
    assert out =~ "yes (you have hidden it)"
  end

  test "meetings on every board, with --json passing the answer through" do
    body =
      ~s({"meetings":{"enabled":true,"visibility":"every_board","hideable":false,"hidden":false}})

    serve([{200, body}, {200, body}])

    assert capture_io(fn -> Meetings.run("meetings", [], []) end) =~ "on every board"

    json = capture_io(fn -> Meetings.run("meetings", [], json: true) end)
    assert %{"meetings" => %{"visibility" => "every_board"}} = JSON.decode!(json)
  end

  test "admin set sends the switches as booleans and the visibility as a word" do
    serve([
      {200,
       ~s({"build":{"git_short_sha":"abc","built_at":"2026-10-09"},"settings":{"signup_mode":"closed","limits":{"trial":{"enabled":false},"boards":{"enabled":true,"limit":1000},"items":{"enabled":true,"limit":250000},"storage":{"enabled":true,"limit_mb":10240}},"user_directory":"instance","invites_create_accounts":true,"smtp":{"configured":false},"login_fallback":{"enabled":false},"analytics":{},"ai":{"source":"none"},"meetings":{"enabled":true,"visibility":"every_board","hideable":false},"pending_signups":0}})}
    ])

    out =
      capture_io(fn ->
        Admin.run(
          "admin",
          [
            "set",
            "meetings_enabled=on",
            "meetings_visibility=every_board",
            "meetings_hideable=no"
          ],
          []
        )
      end)

    assert_received {:request, "PATCH", "/api/admin/settings", body}

    assert JSON.decode!(body) == %{
             "meetings_enabled" => true,
             "meetings_visibility" => "every_board",
             "meetings_hideable" => false
           }

    assert out =~ "Meeting mode:     on, every board"
  end

  describe "capture" do
    @capture ~s({"capture":{"id":12,"title":"Pricing sync","state":"reading","url":"https://x/boards/3/meetings/12","counts":{"open_questions":0},"findings":[],"questions":[]},"existing":false})

    @reviewed ~s({"capture":{"id":12,"title":"Pricing sync","state":"needs_review","url":"https://x/boards/3/meetings/12","findings":[{"id":5,"kind":"decision","title":"Annual plan","status":"kept","included":true,"becomes":"an entry on Decisions / Pricing","evidence":[{"quote":"We go annual.","speaker":"Sam","line":"L2"}]},{"id":6,"kind":"idea","title":"Gone","status":"dropped","included":false}],"questions":[{"id":9,"prompt":"Who is Sammy?","status":"open","options":[{"value":"user:2","label":"Sam Smith"},{"value":"none","label":"Nobody yet"}]}]}})

    defp file(name, contents) do
      path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
      File.write!(path, contents)
      on_exit(fn -> File.rm(path) end)
      path
    end

    test "new with a transcript sends it as JSON and prints the id, link and questions" do
      serve([{201, @capture}])
      t = file("m.vtt", "WEBVTT\n\n00:00.000 --> 00:01.000\n<v Sam>Hi</v>\n")

      out =
        capture_io(fn ->
          Meetings.run("capture", ["new", "PL"],
            transcript: t,
            title: "Pricing sync",
            attendees: "Sam, Priya",
            with_parent: true
          )
        end)

      assert_received {:request, "POST", "/api/boards/PL/captures", body}
      body = JSON.decode!(body)
      assert body["transcript"] =~ "<v Sam>Hi</v>"
      assert body["title"] == "Pricing sync"
      assert body["attendees"] == "Sam, Priya"
      assert body["parent"] == "true"
      assert body["source"] == "agent"

      assert out =~ "sent: capture #12 “Pricing sync” (reading)"
      assert out =~ "https://x/boards/3/meetings/12"
      assert out =~ "questions: 0 so far"
    end

    test "new with a recording sends multipart, the transcript alongside" do
      serve([{201, @capture}])
      audio = file("call.mp3", "ID3 fake audio bytes")
      t = file("m.srt", "1\n00:00:00,000 --> 00:00:01,000\nSam: Hi\n")

      capture_io(fn -> Meetings.run("capture", ["new", "PL"], audio: audio, transcript: t) end)

      assert_received {:request, "POST", "/api/boards/PL/captures", body}
      assert body =~ ~s(name="audio"; filename=")
      assert body =~ "content-type: audio/mpeg"
      assert body =~ "ID3 fake audio bytes"
      assert body =~ ~s(name="transcript"; filename=")
      assert body =~ "Sam: Hi"
    end

    test "new for a meeting already sent says so" do
      serve([{200, String.replace(@capture, ~s("existing":false), ~s("existing":true))}])
      t = file("m.txt", "Sam: Hi")

      assert capture_io(fn -> Meetings.run("capture", ["new", "PL"], transcript: t) end) =~
               "already sent: capture #12"
    end

    test "ls, and --json passes the answer through" do
      list =
        ~s({"captures":[{"id":12,"title":"Pricing sync","state":"ready","started_at":"2026-10-07T10:00:00Z"}]})

      serve([{200, list}, {200, list}])

      assert capture_io(fn -> Meetings.run("capture", ["ls", "PL"], []) end) =~
               "#12  ready        Pricing sync"

      assert_received {:request, "GET", "/api/boards/PL/captures", _}

      json = capture_io(fn -> Meetings.run("capture", ["ls", "PL"], json: true) end)
      assert %{"captures" => [%{"id" => 12}]} = JSON.decode!(json)
    end

    test "show lists what was found and the questions with numbered answers" do
      serve([{200, @reviewed}])
      out = capture_io(fn -> Meetings.run("capture", ["show", "12"], []) end)
      assert_received {:request, "GET", "/api/captures/12", _}

      assert out =~ "[x] 5  decision: Annual plan"
      assert out =~ "becomes → an entry on Decisions / Pricing"
      assert out =~ "“We go annual.” — Sam, L2"
      assert out =~ "1 dropped"
      assert out =~ "9  Who is Sammy?"
      assert out =~ "1. Sam Smith"
      assert out =~ "2. Nobody yet"
    end

    test "resolve sends the answer as given, with what was replayed" do
      serve([{200, @reviewed}])

      capture_io(fn ->
        Meetings.run("capture", ["resolve", "12", "9", "Sam Smith"], replayed: "0:09-0:14")
      end)

      assert_received {:request, "POST", "/api/captures/12/resolve", body}

      assert JSON.decode!(body) == %{
               "question" => "9",
               "answer" => "Sam Smith",
               "replayed" => "0:09-0:14"
             }
    end

    test "include and leave-out" do
      serve([{200, @reviewed}, {200, @reviewed}])
      capture_io(fn -> Meetings.run("capture", ["leave-out", "12", "5"], []) end)
      assert_received {:request, "POST", "/api/captures/12/findings/5", body}
      assert JSON.decode!(body) == %{"included" => false}

      capture_io(fn -> Meetings.run("capture", ["include", "12", "5"], []) end)
      assert_received {:request, "POST", "/api/captures/12/findings/5", body}
      assert JSON.decode!(body) == %{"included" => true}
    end

    test "preview prints the changes and the digest to commit with" do
      preview =
        ~s({"preview":{"digest":"abc123","changes":[{"op":"create_card","title":"Tell sales","list":"To Do"},{"op":"update_card","ref":"#4","title":"Refresh","fields":{"due_date":{"from":null,"to":"2026-10-09"}}},{"op":"decision_entry","page_title":"Decisions / Pricing","lines_added":["- x"]}],"left_out":[{"title":"Maybe","why":"left out in review"}]},"stale":[]})

      serve([{200, preview}])
      out = capture_io(fn -> Meetings.run("capture", ["preview", "12"], []) end)
      assert out =~ "new card “Tell sales” in To Do"
      assert out =~ ~s(#4 “Refresh”: due_date nil → "2026-10-09")
      assert out =~ "1 decision(s) on Decisions / Pricing"
      assert out =~ "left out: Maybe"
      assert out =~ "--preview abc123"
    end

    test "commit sends the preview digest; undo --rest; retry; discard" do
      done =
        ~s({"capture":{"id":12,"title":"Pricing sync","state":"committed","url":"u","findings":[],"questions":[]}})

      serve([{200, done}, {200, done}, {200, done}, {200, done}])

      assert capture_io(fn -> Meetings.run("capture", ["commit", "12"], preview: "abc123") end) =~
               "committed capture #12"

      assert_received {:request, "POST", "/api/captures/12/commit", body}
      assert JSON.decode!(body) == %{"preview" => "abc123"}

      assert capture_io(fn -> Meetings.run("capture", ["undo", "12"], rest: true) end) =~
               "undid capture #12"

      assert_received {:request, "POST", "/api/captures/12/undo", body}
      assert JSON.decode!(body) == %{"rest" => true}

      capture_io(fn -> Meetings.run("capture", ["retry", "12"], []) end)
      assert_received {:request, "POST", "/api/captures/12/retry", _}

      assert capture_io(fn -> Meetings.run("capture", ["discard", "12"], []) end) =~
               "nothing from it was written"

      assert_received {:request, "POST", "/api/captures/12/discard", _}
    end

    test "schema prints the findings format" do
      serve([{200, ~s({"title":"Meeting findings","type":"object"})}])
      assert capture_io(fn -> Meetings.run("capture", ["schema"], []) end) =~ "Meeting findings"
      assert_received {:request, "GET", "/api/meetings/findings-schema", _}
    end
  end
end
