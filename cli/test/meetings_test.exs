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
end
