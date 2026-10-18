defmodule SlipdockCLI.HandoffTest do
  @moduledoc "`slipdock handoff`: writing, clearing and reading a card's handoff, and `card` showing it."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-handoff-#{System.unique_integer([:positive])}")
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

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @written ~s({"card":7,"handoff":{"id":1,"next_step":"Run the suite","body":null,"via":"cli","cleared":false,"at":"2026-10-18T00:30:00Z","by":{"name":"Ada"}}})

  test "--next writes it, with the note, as from the command line" do
    serve([{201, @written}])

    out =
      capture_io(fn ->
        Boards.run("handoff", ["7"], next: "Run the suite", body: "State: half done")
      end)

    assert_received {:request, "POST", "/api/cards/7/handoff", body}

    assert JSON.decode!(body) == %{
             "next_step" => "Run the suite",
             "body" => "State: half done",
             "via" => "cli"
           }

    assert out =~ "left a handoff on #7: Run the suite"
  end

  test "--file reads the note from a file", %{home: home} do
    path = Path.join(home, "note.md")
    File.write!(path, "Gotchas: the cache")
    serve([{201, @written}])

    capture_io(fn -> Boards.run("handoff", ["7"], next: "Go", file: path) end)
    assert_received {:request, "POST", "/api/cards/7/handoff", body}
    assert JSON.decode!(body)["body"] == "Gotchas: the cache"
  end

  test "--body - reads the note from stdin" do
    serve([{201, @written}])

    capture_io([input: "Piped note"], fn ->
      Boards.run("handoff", ["7"], next: "Go", body: "-")
    end)

    assert_received {:request, "POST", "/api/cards/7/handoff", body}
    assert JSON.decode!(body)["body"] == "Piped note"
  end

  test "--clear clears it" do
    serve([{201, ~s({"card":7,"handoff":{"id":2,"next_step":null,"cleared":true}})}])

    out = capture_io(fn -> Boards.run("handoff", ["7"], clear: true) end)
    assert_received {:request, "POST", "/api/cards/7/handoff", body}
    assert JSON.decode!(body) == %{"clear" => true, "via" => "cli"}
    assert out =~ "cleared the handoff on #7"
  end

  test "with no option it shows the handoff and the history, clears marked" do
    serve([
      {200,
       ~s({"card":7,"handoff":{"next_step":"Run the suite","body":"State: done","via":"mcp","at":"2026-10-18T00:30:00Z","by":{"name":"Ada"}},) <>
         ~s("history":[{"next_step":"Run the suite","via":"mcp","cleared":false,"at":"2026-10-18T00:30:00Z","by":{"name":"Ada"}},) <>
         ~s({"next_step":null,"via":"ui","cleared":true,"at":"2026-10-17T10:00:00Z","by":null}]})}
    ])

    out = capture_io(fn -> Boards.run("handoff", ["7"], []) end)
    assert_received {:request, "GET", "/api/cards/7/handoff", _}
    assert out =~ "#7 left off: Run the suite"
    assert out =~ "State: done"
    assert out =~ "Ada · 2026-10-18T00:30 · mcp"
    assert out =~ "(cleared)  someone · 2026-10-17T10:00 · ui"
  end

  test "a card with none says so" do
    serve([{200, ~s({"card":7,"handoff":null,"history":[]})}])
    out = capture_io(fn -> Boards.run("handoff", ["7"], []) end)
    assert out =~ "#7 has no handoff."
    refute out =~ "History"
  end

  describe "slipdock card" do
    defp card(handoff) do
      %{
        "id" => 12,
        "title" => "Left",
        "board_id" => 3,
        "handoff" => handoff,
        "blocked" => false,
        "blocked_by" => [],
        "blocks" => [],
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "attachments" => [],
        "urls" => [],
        "links" => []
      }
    end

    test "shows the handoff first, with who, when, how and the job" do
      out =
        capture_io(fn ->
          Render.card(
            card(%{
              "next_step" => "Fix the flaky test",
              "body" => "Gotchas: seed 42",
              "via" => "runner",
              "job_id" => 9,
              "at" => "2026-10-18T00:30:00Z",
              "by" => %{"email" => "bot@example.com"}
            })
          )
        end)

      [left | _] = out |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/Left off|Priority/))
      assert left =~ "Left off:     Fix the flaky test"
      assert out =~ "bot@example.com · 2026-10-18T00:30 · runner · job #9"
      assert out =~ "Gotchas: seed 42"
    end

    test "says nothing of it when there is none" do
      out = capture_io(fn -> Render.card(card(nil)) end)
      refute out =~ "Left off"
    end
  end
end
