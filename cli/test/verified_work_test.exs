defmodule SlipdockCLI.VerifiedWorkTest do
  @moduledoc """
  Verified work (#1620) on the CLI: the board switches `set-board` sends,
  `edit --bar`, `done --evidence`, `verify`, and what `card` shows. The
  usage refusals end in `System.halt/1`, so they are not run here; the
  server's own (a rejection with no reason) are in
  `SlipdockWeb.VerifiedVerifyWebTest`.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-verified-#{System.unique_integer([:positive])}")
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

  defp parse(argv) do
    {opts, _args, []} = OptionParser.parse(argv, strict: SlipdockCLI.switches())
    opts
  end

  @board ~s({"board":{"id":3,"name":"Docs"}})
  @card ~s({"card":{"id":12,"title":"Work","column":"To Do","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

  test "set-board --bar-required and --no-bar-required send the switch" do
    serve([{200, @board}, {200, @board}])

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--bar-required"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"bar_required" => true}

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--no-bar-required"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"bar_required" => false}
  end

  test "set-board --verify-rejection-limit sends the number, 0 too (#1779)" do
    serve([{200, @board}, {200, @board}])

    capture_io(fn ->
      Boards.run("set-board", ["docs"], parse(["--verify-rejection-limit", "3"]))
    end)

    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"verify_rejection_limit" => 3}

    capture_io(fn ->
      Boards.run("set-board", ["docs"], parse(["--verify-rejection-limit", "0"]))
    end)

    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"verify_rejection_limit" => 0}
  end

  test "set-board --verify-audit sends the 1 in N (#1780)" do
    serve([{200, @board}])
    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--verify-audit", "10"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"verify_audit" => 10}
  end

  test "set-board --findings-propose-at sends the threshold (#1942)" do
    serve([{200, @board}])

    capture_io(fn ->
      Boards.run("set-board", ["docs"], parse(["--findings-propose-at", "0"]))
    end)

    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"findings_propose_at" => 0}
  end

  test "verify agree and disagree post an audit's say (#1780)" do
    serve([{200, @card}, {200, @card}])

    out =
      capture_io(fn ->
        Boards.run("verify", ["12", "agree"], parse(["--reason", "Fine", "--check", "bar:1=ok"]))
      end)

    assert out =~ "audited: agrees"
    assert_received {:request, "POST", "/api/cards/12/verify", body}

    assert JSON.decode!(body) == %{
             "decision" => "agree",
             "reason" => "Fine",
             "checks" => ["bar:1=ok"]
           }

    capture_io(fn ->
      Boards.run("verify", ["12", "disagree"], parse(["--reason", "bar 1: no"]))
    end)

    assert_received {:request, "POST", "/api/cards/12/verify", body}
    assert JSON.decode!(body) == %{"decision" => "disagree", "reason" => "bar 1: no"}
  end

  test "set-board --verify-work --verify-pool sends both" do
    serve([{200, @board}])

    capture_io(fn ->
      Boards.run("set-board", ["docs"], parse(["--verify-work", "--verify-pool", "checkers"]))
    end)

    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"verify_work" => true, "verify_pool" => "checkers"}
  end

  test "edit --bar sends the card's bar" do
    serve([{200, @card}])
    capture_io(fn -> Boards.run("edit", ["12"], parse(["--bar", "Tests pass"])) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"bar" => "Tests pass"}
  end

  test "set-board --evidence-required sends the switch" do
    serve([{200, @board}])
    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--no-evidence-required"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"evidence_required" => false}
  end

  test "done --evidence --evidence-commit sends them with the completion; done alone doesn't" do
    serve([{200, @card}, {200, @card}])

    capture_io(fn ->
      Boards.run(
        "done",
        ["12"],
        parse(["--evidence", "3 passed", "--evidence-commit", "abc1234"])
      )
    end)

    assert_received {:request, "PATCH", "/api/cards/12", body}

    assert JSON.decode!(body) == %{
             "completed" => true,
             "evidence" => "3 passed",
             "evidence_commit" => "abc1234"
           }

    capture_io(fn -> Boards.run("done", ["12"], []) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"completed" => true}
  end

  describe "done --evidence - (#1966)" do
    test "reads the evidence from stdin, line breaks and all, not a literal -" do
      serve([{200, @card}])
      evidence = "**Checked.**\n\n- CI green\n- Handbook: no change\n"

      capture_io([input: evidence], fn ->
        Boards.run("done", ["12"], parse(["--evidence", "-", "--pr", "https://example.com/pr/1"]))
      end)

      assert_received {:request, "PATCH", "/api/cards/12", body}
      sent = JSON.decode!(body)
      assert sent["evidence"] == evidence
      assert sent["evidence_pr"] == "https://example.com/pr/1"
    end

    test "reads stdin once and sends the same evidence with every id" do
      serve([{200, @card}, {200, @card}])

      capture_io([input: "one run"], fn ->
        Boards.run("done", ["12", "13"], parse(["--evidence", "-"]))
      end)

      assert_received {:request, "PATCH", "/api/cards/12", first}
      assert_received {:request, "PATCH", "/api/cards/13", second}
      assert JSON.decode!(first)["evidence"] == "one run"
      assert JSON.decode!(second)["evidence"] == "one run"
    end

    test "evidence that only starts with - is sent as written" do
      serve([{200, @card}])
      capture_io(fn -> Boards.run("done", ["12"], parse(["--evidence", "- CI green"])) end)
      assert_received {:request, "PATCH", "/api/cards/12", body}
      assert JSON.decode!(body)["evidence"] == "- CI green"
    end

    test "empty or unreadable stdin is refused, naming the flag" do
      alias SlipdockCLI.Util

      assert Util.stdin_text(:eof, "--evidence") == {:error, "nothing on stdin for --evidence -"}

      assert Util.stdin_text("  \n", "--evidence") ==
               {:error, "nothing on stdin for --evidence -"}

      assert Util.stdin_text({:error, :terminated}, "--evidence") ==
               {:error, "could not read --evidence from stdin"}

      assert Util.stdin_text("ok\n", "--evidence") == {:ok, "ok\n"}
    end
  end

  test "done --branch --tests --suite send the structured evidence (#1623)" do
    serve([{200, @card}])

    capture_io(fn ->
      Boards.run(
        "done",
        ["12"],
        parse(["--branch", "main", "--tests", "a_test.exs, b_test.exs", "--suite", "passed:38:0"])
      )
    end)

    assert_received {:request, "PATCH", "/api/cards/12", body}

    assert JSON.decode!(body) == %{
             "completed" => true,
             "evidence_branch" => "main",
             "evidence_tests" => ["a_test.exs", "b_test.exs"],
             "evidence_suite" => %{"result" => "passed", "passed" => 38, "failed" => 0}
           }
  end

  test "card shows the structured evidence" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "evidence_commit" => "abc1234",
            "evidence_branch" => "main",
            "evidence_tests" => ["a_test.exs"],
            "evidence_suite" => %{"result" => "failed", "passed" => 3, "failed" => 1}
          })
        )
      end)

    assert out =~ "at abc1234 on main"
    assert out =~ "suite: failed (3 passed, 1 failed)"
    assert out =~ "test: a_test.exs"
  end

  test "card shows the evidence and its commit" do
    out =
      capture_io(fn ->
        Render.card(card(%{"evidence" => "3 passed", "evidence_commit" => "abc1234"}))
      end)

    assert out =~ "Evidence"
    assert out =~ "at abc1234"
    assert out =~ "3 passed"
    refute capture_io(fn -> Render.card(card(%{})) end) =~ "Evidence"
  end

  test "verify accept and reject post the decision; a reject needs --reason" do
    serve([{200, @card}, {200, @card}])

    capture_io(fn ->
      Boards.run("verify", ["12", "accept"], parse(["--evidence-commit", "abc1234"]))
    end)

    assert_received {:request, "POST", "/api/cards/12/verify", body}
    assert JSON.decode!(body) == %{"decision" => "accept", "commit" => "abc1234"}

    out =
      capture_io(fn -> Boards.run("verify", ["12", "reject"], parse(["--reason", "Fails"])) end)

    assert out =~ "rejected"
    assert_received {:request, "POST", "/api/cards/12/verify", body}
    assert JSON.decode!(body) == %{"decision" => "reject", "reason" => "Fails"}
  end

  test "accept and reject are verify by their own names" do
    serve([{200, @card}, {200, @card}])
    capture_io(fn -> Boards.run("accept", ["12"], []) end)
    assert_received {:request, "POST", "/api/cards/12/verify", body}
    assert JSON.decode!(body) == %{"decision" => "accept"}

    capture_io(fn -> Boards.run("reject", ["12"], parse(["--reason", "No"])) end)
    assert_received {:request, "POST", "/api/cards/12/verify", body}
    assert JSON.decode!(body) == %{"decision" => "reject", "reason" => "No"}
  end

  test "card shows how often its work was rejected" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "verify_state" => "rejected",
            "verify_rejections" => 2,
            "verify_by" => %{"kind" => "agent", "agent" => "checker"}
          })
        )
      end)

    assert out =~ "rejected by agent “checker”"
    assert out =~ "rejected 2×"
  end

  test "card shows where verification stands" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "verify_state" => "pending",
            "verify_submitter" => %{"kind" => "agent", "agent" => "builder"}
          })
        )
      end)

    assert out =~ "Verification"
    assert out =~ "pending — submitted by agent “builder”"

    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "verify_state" => "rejected",
            "verify_note" => "Fails on empty",
            "verify_by" => %{"kind" => "human"}
          })
        )
      end)

    assert out =~ "rejected by a person"
    assert out =~ "Fails on empty"
    refute capture_io(fn -> Render.card(card(%{})) end) =~ "Verification"
  end

  test "verify sends each --check, and --checks-file's lines or JSON map (#1778)" do
    serve([{200, @card}, {200, @card}, {200, @card}])

    capture_io(fn ->
      Boards.run(
        "verify",
        ["12", "reject"],
        parse([
          "--reason",
          "Two things",
          "--check",
          "bar:1=ok",
          "--check",
          ~s(rule:UX-4=broken:"hex in card.ex")
        ])
      )
    end)

    assert_received {:request, "POST", "/api/cards/12/verify", body}

    assert JSON.decode!(body) == %{
             "decision" => "reject",
             "reason" => "Two things",
             "checks" => ["bar:1=ok", ~s(rule:UX-4=broken:"hex in card.ex")]
           }

    dir = System.get_env("HOME")
    lines = Path.join(dir, "checks.txt")
    File.write!(lines, "ask=ok\n\nbar:1=ok\nsuite=12:0\n")

    capture_io(fn ->
      Boards.run(
        "verify",
        ["12", "accept"],
        parse(["--check", "handbook_line=ok", "--checks-file", lines])
      )
    end)

    assert_received {:request, "POST", "/api/cards/12/verify", body}

    assert JSON.decode!(body)["checks"] == [
             "handbook_line=ok",
             "ask=ok",
             "bar:1=ok",
             "suite=12:0"
           ]

    map = Path.join(dir, "checks.json")
    File.write!(map, ~s({"ask": "ok", "bar": [{"item": "1", "result": "ok"}]}))

    capture_io(fn ->
      Boards.run("verify", ["12", "accept"], parse(["--checks-file", map]))
    end)

    assert_received {:request, "POST", "/api/cards/12/verify", body}

    assert JSON.decode!(body)["checks"] == %{
             "ask" => "ok",
             "bar" => [%{"item" => "1", "result" => "ok"}]
           }
  end

  test "card lists the verdict's parts under Verification, not while pending (#1778)" do
    checks = %{
      "ask" => "misses",
      "bar" => [
        %{"item" => "1", "result" => "ok"},
        %{"item" => "2", "result" => "fail", "note" => "no footer"}
      ],
      "suite" => %{"passed" => 40, "failed" => 0},
      "rules" => [%{"id" => "UX-4", "result" => "broken", "severity" => "must", "note" => "hex"}],
      "handbook_line" => "ok",
      "notes" => %{"ask" => "the footer"}
    }

    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "verify_state" => "rejected",
            "verify_by" => %{"kind" => "agent", "agent" => "checker"},
            "verify_checks" => checks
          })
        )
      end)

    assert out =~ "✗ the ask misses: the footer"
    assert out =~ "✓ bar 1"
    assert out =~ "✗ bar 2: no footer"
    assert out =~ "✓ suite 40 passed, 0 failed"
    assert out =~ "✗ UX-4 must broken: hex"
    assert out =~ "✓ Handbook line"

    out =
      capture_io(fn ->
        Render.card(card(%{"verify_state" => "pending", "verify_checks" => checks}))
      end)

    refute out =~ "bar 2"
  end

  test "card shows a part carried from an earlier verdict, and the commit it passed at" do
    checks = %{
      "ask" => "ok",
      "carried" => %{"ask" => "abc1234def"},
      "bar" => [
        %{"item" => "1", "result" => "ok", "carried_from" => "abc1234def", "note" => "tidy"},
        %{"item" => "2", "result" => "ok"}
      ],
      "rules" => [%{"id" => "UX-4", "result" => "ok", "carried_from" => "abc1234def"}],
      "judged_at" => "fedcba9876",
      "decision" => "accept"
    }

    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "verify_state" => "accepted",
            "verify_by" => %{"kind" => "agent", "agent" => "checker"},
            "verify_checks" => checks
          })
        )
      end)

    assert out =~ "✓ the ask: carried from abc1234"
    assert out =~ "✓ bar 1: carried from abc1234; tidy"
    assert out =~ "✓ UX-4: carried from abc1234"
    assert out =~ "✓ bar 2\n"
    refute out =~ "bar 2: carried"
  end

  test "card shows a pre-existing rule hit apart from passed and failed parts, with its place" do
    checks = %{
      "bar" => [%{"item" => "1", "result" => "ok"}],
      "rules" => [
        %{
          "id" => "UX-4",
          "severity" => "must",
          "result" => "pre-existing",
          "file" => "lib/card.ex",
          "line" => 42,
          "note" => "hex"
        },
        %{"id" => "UX-5", "result" => "pre-existing", "file" => "lib/a.ex", "line" => 7}
      ]
    }

    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "verify_state" => "accepted",
            "verify_by" => %{"kind" => "agent", "agent" => "checker"},
            "verify_checks" => checks
          })
        )
      end)

    assert out =~ "✓ bar 1"
    assert out =~ "○ UX-4 must pre-existing: lib/card.ex:42; hex"
    assert out =~ "○ UX-5 pre-existing: lib/a.ex:7"
    refute out =~ "✗"
  end

  defp card(extra) do
    Map.merge(
      %{
        "id" => 12,
        "title" => "Work",
        "board_id" => 3,
        "blocked_by" => [],
        "blocks" => [],
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "urls" => [],
        "links" => [],
        "attachments" => []
      },
      extra
    )
  end

  test "card shows the bar and whether it has locked, and nothing without one" do
    out = capture_io(fn -> Render.card(card(%{"bar" => "Tests pass"})) end)
    assert out =~ "Bar"
    assert out =~ "not locked yet"
    assert out =~ "Tests pass"

    out =
      capture_io(fn ->
        Render.card(card(%{"bar" => "Tests pass", "bar_locked_at" => "2026-11-02T10:00:00Z"}))
      end)

    assert out =~ "locked"
    refute out =~ "not locked"

    refute capture_io(fn -> Render.card(card(%{})) end) =~ "Bar"
  end
end
