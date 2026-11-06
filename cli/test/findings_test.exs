defmodule SlipdockCLI.FindingsTest do
  @moduledoc "`slipdock findings` and `slipdock finding`: what they send and show (W-2310)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Findings}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-findings-#{System.unique_integer([:positive])}")
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

  @open %{
    "id" => 4,
    "kind" => "gotcha",
    "source" => "agent",
    "status" => "open",
    "text" => "mix format can need two passes",
    "card" => %{"id" => 1781, "title" => "Findings"},
    "count" => 1
  }

  @merged %{
    "id" => 5,
    "kind" => "process",
    "source" => "timeout",
    "status" => "merged",
    "text" => "job #9 timed out",
    "card" => %{"id" => 12},
    "count" => 3,
    "merged_into_id" => 4,
    "note" => "same cause"
  }

  test "findings <board> lists them, with the filters as the query" do
    serve([{200, JSON.encode!(%{"findings" => [@open, @merged]})}])

    out =
      capture_io(fn ->
        Findings.run("findings", ["slipdock"], kind: ["rule", "gotcha"], days: 7, card: "1781")
      end)

    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/slipdock/findings?"
    assert path =~ "kind=gotcha"
    assert path =~ "since=7"
    assert path =~ "card=1781"
    refute path =~ "status="

    assert out =~ "#4 gotcha (agent #1781): mix format can need two passes"
    assert out =~ "#5 [merged] process (timeout #12) ×3: job #9 timed out → #4 — same cause"
  end

  # #1941: one row per lesson, with the other cards it was said on, and a
  # runner's tooling only with --scope.
  test "--scope goes in the query; a row names the other cards and the runner" do
    lesson =
      Map.merge(@open, %{
        "count" => 2,
        "cards" => [%{"id" => 1781}, %{"id" => 12}, %{"id" => 13}]
      })

    runner =
      Map.merge(@open, %{
        "id" => 6,
        "kind" => "tooling",
        "scope" => "runner",
        "runner" => %{"id" => 2, "name" => "laptop"},
        "text" => "the installed CLI lags"
      })

    serve([{200, JSON.encode!(%{"findings" => [lesson, runner]})}])
    out = capture_io(fn -> Findings.run("findings", ["slipdock"], scope: "all") end)

    assert_received {:request, "GET", path, _}
    assert path =~ "scope=all"
    assert out =~ "#4 gotcha (agent #1781, also #12 #13) ×2: mix format can need two passes"
    assert out =~ "#6 tooling [runner laptop] (agent #1781): the installed CLI lags"
  end

  test "a runner's finding with no runner known still says runner" do
    line = Findings.line(Map.merge(@open, %{"scope" => "runner", "kind" => "tooling"}))
    assert line =~ "tooling [runner] (agent #1781)"
  end

  test "nothing open says so; nothing in another status too" do
    serve([{200, JSON.encode!(%{"findings" => []})}, {200, JSON.encode!(%{"findings" => []})}])
    assert capture_io(fn -> Findings.run("findings", ["b"], []) end) =~ "No open findings."
    assert capture_io(fn -> Findings.run("findings", ["b"], status: "all") end) =~ "No findings."
  end

  test "finding <id> promote sends the action and the note" do
    serve([{200, JSON.encode!(%{"finding" => Map.put(@open, "status", "promoted")})}])

    out =
      capture_io(fn -> Findings.run("finding", ["4", "promote"], note: "W-1950 §Tests") end)

    assert_received {:request, "PATCH", "/api/findings/4", body}
    assert JSON.decode!(body) == %{"action" => "promote", "note" => "W-1950 §Tests"}
    assert out =~ "finding #4 [promoted] gotcha"
  end

  test "finding <id> merge sends --into" do
    serve([{200, JSON.encode!(%{"finding" => @merged})}])
    capture_io(fn -> Findings.run("finding", ["5", "merge"], into: 4) end)
    assert_received {:request, "PATCH", "/api/findings/5", body}
    assert %{"action" => "merge", "into" => 4} = JSON.decode!(body)
  end

  test "merge without --into, and an unknown action, are refused before any request" do
    assert Findings.body("merge", []) ==
             {:error, "merge needs --into <finding id>: the one it joins"}

    assert {:ok, %{"action" => "dismiss"}} = Findings.body("dismiss", [])
    assert "finding" in Findings.commands() and "findings" in Findings.commands()
  end

  test "slipdock card shows a card's open findings, and nothing when there are none" do
    card = %{
      "id" => 7,
      "board_id" => 3,
      "title" => "Build",
      "column" => "In Progress",
      "priority" => "none",
      "flags" => [],
      "tags" => [],
      "checklist" => %{"done" => 0, "total" => 0},
      "comments" => [],
      "blocked_by" => [],
      "blocks" => []
    }

    out = capture_io(fn -> SlipdockCLI.Render.card(Map.put(card, "findings", 2)) end)
    assert out =~ ~r/Findings:\s+2 open · slipdock findings 3 --card 7/

    refute capture_io(fn -> SlipdockCLI.Render.card(Map.put(card, "findings", 0)) end) =~
             "Findings:"
  end
end
