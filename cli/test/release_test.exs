defmodule SlipdockCLI.ReleaseTest do
  @moduledoc """
  `slipdock release <board>` (Release now) and `slipdock releases <board>`
  (#2835): what they send and print, and `set-board --release-command`.
  The server's side is in `test/slipdock_web/release_now_test.exs`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, HTTP, Runners}

  @vars ~w(HOME CLAUDECODE SLIPDOCK_JOB_ID SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN)

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  @request %{
    "id" => 9,
    "board_id" => 3,
    "status" => "running",
    "triggers" => [%{"trigger" => "manual", "by" => "Dana", "at" => "2026-11-12T10:00:00Z"}],
    "card_ids" => [41, 42],
    "job_id" => 77,
    "run_url" => nil,
    "note" => nil
  }

  @awaiting [%{"id" => 41, "title" => "One"}, %{"id" => 42, "title" => "Two"}]

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  test "the commands are routed and the switch parses" do
    assert Enum.member?(Runners.commands(), "release")
    assert Enum.member?(Runners.commands(), "releases")

    {opts, ["set-board", "ops"], []} =
      OptionParser.parse(["set-board", "ops", "--release-command", "make release"],
        strict: SlipdockCLI.switches()
      )

    assert opts[:release_command] == "make release"
  end

  test "release posts and prints how it was placed and where releases stand" do
    release = %{"mode" => "batched", "running" => @request, "queued" => nil, "awaiting" => []}

    serve([
      {201,
       JSON.encode!(%{
         "how" => "started",
         "line" => "Release started: a runner fires the release command next.",
         "request" => @request,
         "release" => release
       })}
    ])

    out = capture_io(fn -> Runners.run("release", ["ops"], []) end)

    assert_received {:request, "POST", "/api/boards/ops/release", _}

    assert out ==
             "Release started: a runner fires the release command next.\n" <>
               "running: #9 running · Release now by Dana · 2 cards · job #77\n" <>
               "awaiting release: none\n"
  end

  test "releases prints the mode, each request and the cards awaiting" do
    last = %{
      @request
      | "id" => 8,
        "status" => "failed",
        "triggers" => [
          %{"trigger" => "critical", "by" => "#40 Hotfix"},
          %{"trigger" => "age_cap", "by" => "#3 has waited 9h, cap 4h"}
        ],
        "run_url" => "https://ci.example.com/runs/5",
        "note" => "the release failed at test"
    }

    queued = %{@request | "id" => 10, "status" => "queued", "card_ids" => [], "job_id" => nil}

    serve([
      {200,
       JSON.encode!(%{
         "release" => %{
           "mode" => "batched",
           "running" => nil,
           "queued" => queued,
           "last" => last,
           "awaiting" => @awaiting
         }
       })}
    ])

    out = capture_io(fn -> Runners.run("releases", ["ops"], []) end)

    assert_received {:request, "GET", "/api/boards/ops/release", _}

    assert out ==
             "release mode: batched\n" <>
               "queued: #10 queued · Release now by Dana · 0 cards\n" <>
               "last: #8 failed · critical card #40 Hotfix, age cap · 2 cards · job #77 · " <>
               "https://ci.example.com/runs/5 · the release failed at test\n" <>
               "awaiting release: 2\n  #41 One\n  #42 Two\n"
  end

  @hold %{
    "reason" => "the release failed at test",
    "stage" => "test",
    "run_url" => "https://ci.example.com/runs/6",
    "fix_card_id" => 50,
    "text" =>
      "the release failed at test (https://ci.example.com/runs/6); fix card #50 releases " <>
        "when it merges, or the board's owner lifts the hold"
  }

  test "releases prints a hold first, saying why with the run (#2838)" do
    serve([
      {200,
       JSON.encode!(%{"release" => %{"mode" => "batched", "hold" => @hold, "awaiting" => []}})}
    ])

    assert capture_io(fn -> Runners.run("releases", ["ops"], []) end) ==
             "release mode: batched\n" <>
               "held: the release failed at test (https://ci.example.com/runs/6); fix card #50 " <>
               "releases when it merges, or the board's owner lifts the hold\n" <>
               "awaiting release: none\n"
  end

  test "release --lift-hold deletes the hold and asks for no release (#2838)" do
    {opts, ["release", "ops"], []} =
      OptionParser.parse(["release", "ops", "--lift-hold"], strict: SlipdockCLI.switches())

    assert opts[:lift_hold] == true

    serve([
      {200,
       JSON.encode!(%{
         "lifted" => @hold,
         "line" => "Release hold lifted. Nothing was released.",
         "release" => %{"mode" => "batched", "hold" => nil, "awaiting" => @awaiting}
       })}
    ])

    out = capture_io(fn -> Runners.run("release", ["ops"], opts) end)

    assert_received {:request, "DELETE", "/api/boards/ops/release/hold", _}
    refute_received {:request, "POST", _, _}

    assert out ==
             "Release hold lifted. Nothing was released.\n" <>
               "awaiting release: 2\n  #41 One\n  #42 Two\n"
  end

  test "a request nothing is recorded as asking for prints no empty field" do
    bare = %{@request | "triggers" => [], "card_ids" => [], "job_id" => nil}
    odd = %{@request | "triggers" => [%{"trigger" => "webhook"}, %{"trigger" => "manual"}]}

    serve([
      {200,
       JSON.encode!(%{
         "release" => %{"mode" => "batched", "running" => bare, "last" => odd, "awaiting" => []}
       })}
    ])

    assert capture_io(fn -> Runners.run("releases", ["ops"], []) end) ==
             "release mode: batched\n" <>
               "running: #9 running · 0 cards\n" <>
               "last: #9 running · a trigger, Release now by somebody · 2 cards · job #77\n" <>
               "awaiting release: none\n"
  end

  test "--json prints the answer as it came" do
    body = %{"release" => %{"mode" => "on_merge", "awaiting" => []}}
    serve([{200, JSON.encode!(body)}])

    out = capture_io(fn -> Runners.run("releases", ["ops"], json: true) end)
    assert JSON.decode!(out) == body
  end

  test "a board that releases on merge: the server's refusal is what release halts on" do
    refusal = %{"error" => "conflict: this board releases on merge"}
    serve([{409, JSON.encode!(refusal)}])

    assert {:error, 409, %{"error" => "conflict: this board releases on merge"}} =
             HTTP.post("/boards/ops/release", %{})
  end

  test "set-board --release-command sends the command; default clears it" do
    assert Boards.release_command(nil) == nil
    assert Boards.release_command("make release") == "make release"
    assert Boards.release_command("default") == ""
    assert Boards.release_command("") == ""

    serve([{200, JSON.encode!(%{"board" => %{"id" => 3, "name" => "Ops", "code" => "ops"}})}])
    capture_io(fn -> Boards.run("set-board", ["ops"], release_command: "make release") end)

    assert_received {:request, "PATCH", "/api/boards/ops", sent}
    assert JSON.decode!(sent) == %{"release_command" => "make release"}
  end
end
