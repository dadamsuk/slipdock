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
end
