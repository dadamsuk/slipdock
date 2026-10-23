defmodule SlipdockCLI.WaitTest do
  @moduledoc """
  `slipdock wait` and `slipdock answer` (#1114): opening a wait with its
  person, choices and job (from `$SLIPDOCK_JOB_ID` unless `--job` says),
  withdrawing it, answering in words or by choice, `--on` read as the
  person only for `wait`, and `card` showing the open wait.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-wait-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    saved =
      Map.new(
        ~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN SLIPDOCK_JOB_ID CLAUDECODE),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN SLIPDOCK_JOB_ID CLAUDECODE), &System.delete_env/1)

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

  @opened ~s({"card":7,"wait":{"id":1,"needs":"Which region?","choices":["eu","us"],"on":{"name":"Dana"},"open":true}})
  @answered ~s({"card":7,"wait":{"id":1,"needs":"Which region?","choice":1,"choice_text":"eu","answer":"for now","open":false}})

  # The options as `slipdock` itself would parse them.
  defp parse(argv) do
    {opts, args, []} =
      OptionParser.parse(SlipdockCLI.wait_on(argv), strict: SlipdockCLI.switches())

    {args, opts}
  end

  test "wait opens one on a person with its choices, and sends no job when there is none" do
    serve([{201, @opened}])

    {["wait", id | words], o} =
      parse(~w(wait 7 Which region? --on dana@example.com --choice eu --choice us))

    out = capture_io(fn -> Boards.run("wait", [id | words], o) end)
    assert_received {:request, "POST", "/api/cards/7/wait", body}

    assert JSON.decode!(body) == %{
             "needs" => "Which region?",
             "on" => "dana@example.com",
             "choices" => ["eu", "us"]
           }

    assert out =~ "#7 waits on Dana: Which region?"
    assert out =~ "1. eu  2. us"
  end

  test "wait sends the job from $SLIPDOCK_JOB_ID, and --job wins over it" do
    System.put_env("SLIPDOCK_JOB_ID", "42")
    serve([{201, @opened}, {201, @opened}])

    capture_io(fn -> Boards.run("wait", ["7", "Which region?"], []) end)
    assert_received {:request, "POST", "/api/cards/7/wait", body}
    assert JSON.decode!(body) == %{"needs" => "Which region?", "job_id" => "42"}

    capture_io(fn -> Boards.run("wait", ["7", "Which region?"], job: "43") end)
    assert_received {:request, "POST", "/api/cards/7/wait", body}
    assert JSON.decode!(body)["job_id"] == "43"
  end

  test "a blank $SLIPDOCK_JOB_ID sends no job" do
    System.put_env("SLIPDOCK_JOB_ID", "  ")
    serve([{201, @opened}])
    capture_io(fn -> Boards.run("wait", ["7", "Which region?"], []) end)
    assert_received {:request, "POST", "/api/cards/7/wait", body}
    refute Map.has_key?(JSON.decode!(body), "job_id")
  end

  test "wait --withdraw withdraws it" do
    serve([{200, ~s({"card":7,"wait":{"needs":"Which region?","close_reason":"withdrawn"}})}])
    out = capture_io(fn -> Boards.run("wait", ["7"], withdraw: true) end)
    assert_received {:request, "DELETE", "/api/cards/7/wait", _}
    assert out =~ "withdrew the wait on #7: Which region?"
  end

  test "answer --choice 1 posts choice 1, with any words beside it" do
    serve([{200, @answered}])
    {["answer", id | words], o} = parse(~w(answer 7 for now --choice 1))

    out = capture_io(fn -> Boards.run("answer", [id | words], o) end)
    assert_received {:request, "POST", "/api/cards/7/wait/answer", body}
    assert JSON.decode!(body) == %{"choice" => 1, "answer" => "for now"}
    assert out =~ "answered #7: eu — for now"
  end

  test "answer in words alone sends no choice" do
    serve([{200, @answered}])
    capture_io(fn -> Boards.run("answer", ["7", "eu-west"], []) end)
    assert_received {:request, "POST", "/api/cards/7/wait/answer", body}
    assert JSON.decode!(body) == %{"answer" => "eu-west"}
  end

  test "--on names the person only for wait; elsewhere it is still a switch" do
    assert {_, o} = parse(~w(wait 7 Size? --on me))
    assert o[:wait_on] == "me"
    refute o[:on]

    assert {["automation", "3"], o} = parse(~w(automation 3 --on))
    assert o[:on] == true
  end

  test "card shows the open wait beside its other fields" do
    card = %{
      "id" => 12,
      "title" => "Held",
      "board_id" => 3,
      "handoff" => nil,
      "wait" => %{
        "needs" => "Which region?",
        "on" => nil,
        "choices" => [],
        "kind" => "agent",
        "opened_by" => %{"email" => "bot@example.com"},
        "opened_at" => "2026-10-19T01:00:00Z",
        "job_id" => 9
      },
      "blocked" => false,
      "blocked_by" => [],
      "blocks" => [],
      "flags" => ["waiting"],
      "tags" => [],
      "assignees" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "comments" => [],
      "attachments" => [],
      "urls" => [],
      "links" => []
    }

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ "Waiting:"
    assert out =~ "waits on anyone: Which region?"
    assert out =~ "bot@example.com (agent) · 2026-10-19T01:00 · job #9"

    refute capture_io(fn -> Render.card(Map.delete(card, "wait")) end) =~ "Waiting:"
  end

  describe "a series of questions (#1220)" do
    @series ~s({"card":7,"wait":{"id":2,"needs":"Before deploy","questions":["Which region?","How many seats?"],"choices":[],"on":null,"open":true}})
    @series_answered ~s({"card":7,"wait":{"id":2,"needs":"Before deploy","questions":["Which region?","How many seats?"],"answers":["eu",""],"open":false,"close_reason":"answered"}})

    test "wait --question once per question sends them, with the words as the intro" do
      serve([{201, @series}])

      {["wait", id | words], o} =
        parse([
          "wait",
          "7",
          "Before",
          "deploy",
          "--question",
          "Which region?",
          "--question",
          "How many seats?"
        ])

      out = capture_io(fn -> Boards.run("wait", [id | words], o) end)
      assert_received {:request, "POST", "/api/cards/7/wait", body}

      assert JSON.decode!(body) == %{
               "needs" => "Before deploy",
               "questions" => ["Which region?", "How many seats?"]
             }

      assert out =~
               "#7 waits on anyone: Before deploy\n    1. Which region?\n    2. How many seats?"
    end

    test "wait with only --question sends no needs" do
      serve([{201, @series}])
      {["wait", id], o} = parse(["wait", "7", "--question", "A?", "--question", "B?"])

      capture_io(fn -> Boards.run("wait", [id], o) end)
      assert_received {:request, "POST", "/api/cards/7/wait", body}
      assert JSON.decode!(body) == %{"questions" => ["A?", "B?"]}
    end

    test "answer --answer once per question sends them in order, blanks kept" do
      serve([{200, @series_answered}])
      {["answer", id], o} = parse(["answer", "7", "--answer", "eu", "--answer", ""])

      out = capture_io(fn -> Boards.run("answer", [id], o) end)
      assert_received {:request, "POST", "/api/cards/7/wait/answer", body}
      assert JSON.decode!(body) == %{"answers" => ["eu", ""]}
      assert out =~ "1. Which region?\n       → eu"
      assert out =~ "2. How many seats?\n       → (not answered)"
    end

    test "answer --skip skips them" do
      serve([
        {200, ~s({"card":7,"wait":{"id":2,"needs":"x","close_reason":"skipped","open":false}})}
      ])

      {["answer", id], o} = parse(~w(answer 7 --skip))

      out = capture_io(fn -> Boards.run("answer", [id], o) end)
      assert_received {:request, "POST", "/api/cards/7/wait/answer", body}
      assert JSON.decode!(body) == %{"skip" => true}
      assert out =~ "skipped the questions on #7"
    end

    test "waits lists every question asked, how each ended, and says when there are none" do
      waits =
        ~s({"card":7,"waits":[) <>
          ~s({"needs":"Before deploy","questions":["Which region?","Seats?"],"answers":["eu","12"],"close_reason":"answered","closed_by":{"name":"Dana"},"opened_by":{"name":"Bot"},"opened_at":"2026-10-23T10:00:00Z"},) <>
          ~s({"needs":"Ready?","questions":[],"close_reason":"skipped","closed_by":{"name":"Dana"},"opened_by":{"name":"Bot"},"opened_at":"2026-10-22T10:00:00Z"},) <>
          ~s({"needs":"Open one?","questions":[],"close_reason":null,"opened_by":{"name":"Bot"},"opened_at":"2026-10-21T10:00:00Z"}]})

      serve([{200, waits}, {200, ~s({"card":8,"waits":[]})}])

      out = capture_io(fn -> Boards.run("waits", ["7"], []) end)
      assert_received {:request, "GET", "/api/cards/7/waits", _}
      assert out =~ "#7 questions"
      assert out =~ "answered by Dana: \n    1. Which region?\n       → eu"
      assert out =~ "skipped by Dana"
      assert out =~ "open"

      assert capture_io(fn -> Boards.run("waits", ["8"], []) end) =~ "#8 has asked no questions"
    end
  end
end
