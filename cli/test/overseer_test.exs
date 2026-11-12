defmodule SlipdockCLI.OverseerTest do
  @moduledoc """
  `slipdock overseer` (#2068): what it sends and what it shows, its
  alerts first in `whoami`, and a condition's what-to-do in `work`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Auth, Boards, FakeServer, Overseer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-overseer-#{System.unique_integer([:positive])}")
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

  defp serve(body),
    do: System.put_env("SLIPDOCK_URL", FakeServer.start([{200, JSON.encode!(body)}]))

  @condition %{
    "id" => 7,
    "check" => "waiting_idle",
    "card_id" => 2044,
    "title" => "Only you can move Ops on: 1 waiting, nothing running",
    "why" => "No runner job is open on the board, and these wait on a person: #2044.",
    "todo" => "Answer the waits.",
    "opened_at" => "2026-11-07T23:40:00Z"
  }

  @state %{
    "overseer" => %{
      "enabled" => true,
      "pool" => "default",
      "min_minutes" => 10,
      "max_minutes" => 120,
      "idle_minutes" => 15,
      "email" => true,
      "digest_at" => "07:00",
      "next_run_at" => "2026-11-08T01:30:00Z",
      "open_job" => nil,
      "last_digest" => %{
        "health" => "at_risk",
        "body" => "Overnight: 4 merged, #2040 took 3 rounds.",
        "at" => "2026-11-08T01:20:00Z"
      },
      "conditions" => [@condition],
      "cleared_last_day" => []
    }
  }

  test "overseer <board> shows where it stands, the digest and the conditions" do
    serve(@state)
    out = capture_io(fn -> Overseer.run("overseer", ["ops"], []) end)

    assert_received {:request, "GET", "/api/boards/ops/overseer", _}
    assert out =~ "Overseer: on"
    assert out =~ "every 10–120 min"
    assert out =~ "Housekeeping digest at 07:00"
    assert out =~ "next pass: 2026-11-08T01:30:00Z"
    assert out =~ "last digest (at_risk, 2026-11-08T01:20:00Z)"
    assert out =~ "#2040 took 3 rounds"
    assert out =~ "[waiting_idle] #2044 Only you can move Ops on"
    assert out =~ "What to do: Answer the waits."
  end

  test "--on and the bounds send a PATCH; --off turns it off" do
    serve(@state)

    capture_io(fn ->
      Overseer.run("overseer", ["ops"], on: true, pool: "watch", min_minutes: 15, max_minutes: 60)
    end)

    assert_received {:request, "PATCH", "/api/boards/ops/overseer", body}

    assert JSON.decode!(body) == %{
             "enabled" => true,
             "pool" => "watch",
             "min_minutes" => 15,
             "max_minutes" => 60
           }

    assert Overseer.changes(off: true, email: false) == %{"enabled" => false, "email" => false}
    assert Overseer.changes(on: true, off: true) == {:error, "--on or --off, not both"}
  end

  test "nothing open says so" do
    serve(put_in(@state, ["overseer", "conditions"], []))
    out = capture_io(fn -> Overseer.run("overseer", ["ops"], []) end)
    assert out =~ "nothing open"
  end

  test "whoami shows the overseer's alerts first" do
    serve(%{
      "user" => %{"email" => "da@example.com", "name" => "David"},
      "limits" => nil,
      "waiting_on_you" => 2,
      "overseer" => [@condition]
    })

    out = capture_io(fn -> Auth.run("whoami", [], []) end)
    [before, _] = String.split(out, "waiting on you: 2")
    assert before =~ "overseer: #2044 Only you can move Ops on"
    assert before =~ "what to do: Answer the waits."
  end

  test "work prints a condition's what to do under it" do
    serve(%{
      "waiting_count" => 1,
      "waiting" => [
        %{
          "reason" => "overseer",
          "text" => "Overseer: " <> @condition["title"],
          "since" => "2026-11-07T23:40:00Z",
          "card" => %{"id" => 2044, "title" => "Docs", "column" => "Doing"},
          "path" => ["Ops"],
          "wait" => nil,
          "condition" => @condition
        }
      ],
      "sections" => []
    })

    out = capture_io(fn -> Boards.run("work", [], []) end)
    assert out =~ "Overseer: Only you can move Ops on"
    assert out =~ "What to do: Answer the waits."
  end

  test "--digest-at sends the morning digest's time (#2781)" do
    serve(@state)
    capture_io(fn -> Overseer.run("overseer", ["ops"], digest_at: "06:30") end)
    assert_received {:request, "PATCH", "/api/boards/ops/overseer", body}
    assert JSON.decode!(body) == %{"digest_at" => "06:30"}
  end
end
