defmodule SlipdockCLI.TimelineTest do
  @moduledoc "`slipdock timeline <id>` (#1131): a card's stays in lists, waits and jobs."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-timeline-#{System.unique_integer([:positive])}")
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

    :ok
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @full ~s({"card":7,"timeline":{"from":"2026-10-01T09:00:00Z","to":"2026-10-01T11:00:00Z",) <>
          ~s("stays":[) <>
          ~s({"list":"To Do","category":"todo","from":"2026-10-01T09:00:00Z","to":"2026-10-01T09:30:00Z","seconds":1800,"open":false,"unsure":true,"how":{"kind":"created","by":null,"backfilled":true}},) <>
          ~s({"list":"In Progress","category":"doing","from":"2026-10-01T09:30:00Z","to":"2026-10-01T11:00:00Z","seconds":5400,"open":true,"unsure":false,"how":{"kind":"moved","by":"Ada","backfilled":false}}],) <>
          ~s("waits":[{"id":3,"needs":"Which colour?","on":"anyone","from":"2026-10-01T10:00:00Z","to":"2026-10-01T10:05:00Z","seconds":300,"open":false,"reason":"answered"}],) <>
          ~s("jobs":[{"id":12,"status":"running","pool":"dev","kind":"claude","runner":"laptop","from":"2026-10-01T10:10:00Z","to":"2026-10-01T11:00:00Z","seconds":3000,"open":true}]}})

  test "every lane, with when, how long and who" do
    serve([{200, @full}])

    out = capture_io(fn -> Boards.run("timeline", ["7"], []) end)

    assert_received {:request, "GET", "/api/cards/7/timeline", _}
    assert out =~ "#7 timeline"
    assert out =~ "since 2026-10-01 09:00 UTC"
    assert out =~ ~r/2026-10-01 09:00  To Do\s+30m\s+.*recovered from the log \(time uncertain\)/
    assert out =~ ~r/2026-10-01 09:30  In Progress\s+1h so far\s+.*moved by Ada/
    assert out =~ ~r/Waits\n  2026-10-01 10:00  on anyone\s+5m\s+.*Which colour\? \(answered\)/
    assert out =~ ~r/Jobs\n  2026-10-01 10:10  #12 running\s+50m so far\s+.*dev · claude · laptop/
  end

  test "lanes with nothing in them are left out" do
    serve([
      {200,
       ~s({"card":7,"timeline":{"from":"2026-10-01T09:00:00Z","to":"2026-10-01T09:10:00Z",) <>
         ~s("stays":[{"list":"To Do","from":"2026-10-01T09:00:00Z","seconds":600,"open":true,"unsure":false,"how":{"kind":"created","by":"Ada"}}],"waits":[],"jobs":[]}})}
    ])

    out = capture_io(fn -> Boards.run("timeline", ["7"], []) end)
    assert out =~ "Lists"
    assert out =~ "created by Ada"
    refute out =~ "Waits"
    refute out =~ "Jobs"
  end

  test "--json prints the server's answer as it is" do
    serve([{200, @full}])
    out = capture_io(fn -> Boards.run("timeline", ["7"], json: true) end)
    assert %{"card" => 7, "timeline" => %{"stays" => [_, _]}} = JSON.decode!(out)
  end
end
