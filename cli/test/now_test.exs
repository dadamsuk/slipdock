defmodule SlipdockCLI.NowTest do
  @moduledoc """
  Right now from the CLI (#2110): `slipdock now <board>` reads
  `GET /api/boards/:board/now` and prints the runners with their jobs'
  steps, the cards in progress with where they sit and what holds them, and
  the queue; `--json` prints the server's JSON as it is. A refusal (a board
  that isn't there, a sub-board whose root can't be read) ends in
  `System.halt/1` through the shared `out/3`, so it is not run here; the
  server's side of it is in `test/slipdock_web/now_test.exs`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Now}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-now-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    saved =
      Map.new(
        ~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN NO_COLOR),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.put_env("NO_COLOR", "1")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(body), do: System.put_env("SLIPDOCK_URL", FakeServer.start([{200, body}]))

  defp ago(secs), do: DateTime.utc_now() |> DateTime.add(-secs) |> DateTime.to_iso8601()

  defp snapshot do
    JSON.encode!(%{
      board_id: 3,
      runners: [
        %{
          id: 1,
          name: "box",
          pool: "default",
          online: true,
          session: false,
          jobs: [
            %{
              id: 12,
              kind: "build",
              status: "running",
              pool: "default",
              card_id: 45,
              card: "Fix login",
              board_id: 3,
              step: "Running the tests",
              step_at: ago(180),
              since: ago(3600)
            },
            %{
              id: 14,
              kind: "verify",
              status: "claimed",
              pool: "default",
              card_id: 50,
              card: "Check it",
              board_id: 3,
              step: nil,
              step_at: nil,
              since: ago(120)
            }
          ]
        },
        %{id: 2, name: "laptop", pool: "loop", online: false, session: true, jobs: []}
      ],
      in_progress: [
        %{
          id: 45,
          title: "Fix login",
          board_id: 3,
          board: "slipdock",
          list: "Doing",
          parent: nil,
          state: "Running · box",
          state_kind: "running",
          loop: %{runner: "box", kind: "build", job_id: 12},
          holds: nil,
          age: 7200
        },
        %{
          id: 61,
          title: "Subcard",
          board_id: 9,
          board: "Epic board",
          list: "In Progress",
          parent: %{id: 40, title: "The epic", board_id: 3},
          state: "Waiting on Dana",
          state_kind: "waiting",
          loop: nil,
          holds: "waiting",
          age: 2 * 86_400
        }
      ],
      queued: [
        %{
          id: 13,
          kind: "build",
          status: "queued",
          pool: "default",
          card_id: 47,
          card: "Next one",
          board_id: 3,
          step: nil,
          step_at: nil,
          since: ago(300),
          held: "#45 is in progress"
        },
        %{
          id: 15,
          kind: "build",
          status: "queued",
          pool: "gpu",
          card_id: 48,
          card: "Nobody to take it",
          board_id: 3,
          step: nil,
          step_at: nil,
          since: ago(30),
          held: nil
        }
      ],
      counts: %{runners: 2, online: 1, working: 1, in_progress: 2, queued: 2}
    })
  end

  test "now reads the board's snapshot, with the board's name encoded in the path" do
    serve(snapshot())
    capture_io(fn -> SlipdockCLI.main(["now", "my board"]) end)
    assert_received {:request, "GET", "/api/boards/my%20board/now", _}
  end

  test "now prints the counts, then runners with their jobs' steps" do
    serve(snapshot())
    out = capture_io(fn -> SlipdockCLI.main(["now", "slipdock"]) end)

    assert out =~ "Right now · 2 runners (1 online, 1 working) · 2 in progress · 2 queued"
    assert out =~ "RUNNERS"
    assert out =~ "box (default) online"
    assert out =~ "job #12 build running  #45 Fix login  — Running the tests · 3m"
    # A job with no step yet says so, and how long since it was claimed.
    assert out =~ "job #14 verify claimed  #50 Check it  — no step yet · 2m"
  end

  test "now lists the idle runners last, after the queue, not among the working ones" do
    serve(snapshot())
    out = capture_io(fn -> SlipdockCLI.main(["now", "slipdock"]) end)

    [runners, rest] = String.split(out, "IN PROGRESS")
    assert runners =~ "box (default) online"
    refute runners =~ "laptop"

    [_queued, idle] = String.split(rest, "IDLE RUNNERS")
    assert rest =~ ~r/QUEUED.*IDLE RUNNERS/s
    # A Claude session is marked as one.
    assert idle =~ "laptop (loop) offline · session"
    refute idle =~ "box"
  end

  test "with every runner idle, RUNNERS says none is working" do
    serve(
      JSON.encode!(%{
        runners: [%{id: 2, name: "laptop", pool: "loop", online: true, session: false, jobs: []}],
        in_progress: [],
        queued: [],
        counts: %{runners: 1, online: 1, working: 0, in_progress: 0, queued: 0}
      })
    )

    out = capture_io(fn -> SlipdockCLI.main(["now", "slipdock"]) end)

    assert out =~ ~r/RUNNERS\n\s+none working/
    assert out =~ ~r/IDLE RUNNERS\n\s+laptop \(loop\) online/
  end

  test "now prints the cards in progress, where they sit and what holds them" do
    serve(snapshot())
    out = capture_io(fn -> SlipdockCLI.main(["now", "slipdock"]) end)
    lines = String.split(out, "\n")

    assert out =~ ~r/CARD\s+WHERE\s+STATE\s+HOLDS\s+RUNNER\s+AGE/
    fix = Enum.find(lines, &String.starts_with?(&1, "#45 Fix login"))
    assert fix =~ ~r/slipdock › Doing\s+Running · box\s+-\s+box build\s+2h$/

    sub = Enum.find(lines, &String.starts_with?(&1, "#61 Subcard"))
    assert sub =~ ~r/Epic board › In Progress \(in #40\)\s+Waiting on Dana\s+waiting\s+-\s+2d$/
  end

  test "now prints the queue, each job with what holds it back" do
    serve(snapshot())
    out = capture_io(fn -> SlipdockCLI.main(["now", "slipdock"]) end)
    lines = String.split(out, "\n")

    assert out =~ ~r/JOB\s+POOL\/KIND\s+CARD\s+HELD\s+QUEUED/

    assert Enum.find(lines, &String.starts_with?(&1, "#13 ")) =~
             ~r/default\/build\s+#47 Next one\s+#45 is in progress\s+5m$/

    assert Enum.find(lines, &String.starts_with?(&1, "#15 ")) =~
             ~r/gpu\/build\s+#48 Nobody to take it\s+waiting for a runner\s+<1m$/
  end

  test "a quiet board says so in each section" do
    serve(
      ~s({"board_id":3,"runners":[],"in_progress":[],"queued":[],"counts":{"runners":1,"online":0,"working":0,"in_progress":0,"queued":0}})
    )

    out = capture_io(fn -> SlipdockCLI.main(["now", "slipdock"]) end)

    assert out =~ "Right now · 1 runner (0 online, 0 working) · 0 in progress · 0 queued"
    assert out =~ "no runners"
    assert out =~ "nothing in progress"
    assert out =~ "nothing queued"
    refute out =~ "IDLE RUNNERS"
  end

  test "--json prints the server's JSON as it is" do
    body = snapshot()
    serve(body)
    out = capture_io(fn -> SlipdockCLI.main(["now", "slipdock", "--json"]) end)

    assert JSON.decode!(out) == JSON.decode!(body)
    refute out =~ "RUNNERS"
  end

  test "control characters in a title are scrubbed before they reach the terminal" do
    body =
      JSON.encode!(%{
        runners: [],
        queued: [],
        counts: %{},
        in_progress: [
          %{id: 1, title: "Evil\e]52;c;aGk=\aTitle", board: "b", list: "Doing", age: nil}
        ]
      })

    serve(body)
    out = capture_io(fn -> SlipdockCLI.main(["now", "slipdock"]) end)

    assert out =~ "#1 Evil]52;c;aGk=Title"
    refute out =~ "\e]52"
  end

  test "where names the epic a sub-board hangs from" do
    assert Now.where(%{"board" => "b", "list" => "Doing", "parent" => nil}) == "b › Doing"

    assert Now.where(%{"board" => "Epic", "list" => "Doing", "parent" => %{"id" => 40}}) ==
             "Epic › Doing (in #40)"
  end

  test "now is a command the CLI routes" do
    assert "now" in Now.commands()
  end
end
