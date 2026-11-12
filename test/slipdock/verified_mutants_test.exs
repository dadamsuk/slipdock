defmodule Slipdock.VerifiedMutantsTest do
  @moduledoc """
  The mutation review's parts (#2354, #2355): a verifier breaks changed
  lines on purpose and says whether the card's tests caught each. A
  `mutant:killed|survived|pre-existing=<file>:<line>:<mutation>[:note]`
  line, or `mutants=n/a:<why>`, is parsed (and its map form taken back),
  stored as `verify_checks.mutants` and shown. A survivor is a failing part:
  a rejection with its own cause, never an acceptance. A pre-existing
  survivor is a finding and not a rejection. A resubmission carries the
  killed mutants the verifier didn't judge again.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Findings.{Finding, Signals}
  alias Slipdock.Verified.Checks

  @first "aaaa1111bbbb2222"
  @second "cccc3333dddd4444"

  setup do
    owner = user_fixture("mutants-owner@example.com")
    board = board_fixture(%{"name" => "Mutants", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Export", "bar" => "1. CSV"})

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{owner: owner, board: board, card: card, builder: agent.("b"), checker: agent.("c")}
  end

  defp submit(ctx, sha \\ @first) do
    {:ok, card} =
      Boards.Cards.update_card(
        Repo.get!(Card, ctx.card.id),
        %{"completed" => true, "evidence" => "built", "evidence_commit" => sha},
        actor: ctx.builder,
        by: ctx.owner
      )

    assert card.verify_state == "pending"
    card
  end

  defp decide(ctx, decision, params),
    do: Verified.decide(Repo.get!(Card, ctx.card.id), decision, params, ctx.checker, ctx.owner)

  defp findings(card),
    do: Repo.all(from(f in Finding, where: f.card_id == ^card.id, order_by: f.id))

  defp last_body(card),
    do: Boards.Cards.get_card!(card.id).comments |> Enum.max_by(& &1.id) |> Map.fetch!(:body)

  describe "Checks.parse/1, lines" do
    test "each result takes its file, line, mutation and an optional note" do
      assert {:ok, %{"mutants" => [killed, survived, pre]}} =
               Checks.parse([
                 "mutant:killed=lib/a.ex:42:flip > to >=",
                 "mutant:SURVIVED=lib/a.ex:51:drop the nil guard:a test giving nil",
                 "mutant:pre-existing=lib/b.ex:9:return ok:in code the diff left"
               ])

      assert killed == %{
               "result" => "killed",
               "file" => "lib/a.ex",
               "line" => 42,
               "mutation" => "flip > to >="
             }

      assert survived == %{
               "result" => "survived",
               "file" => "lib/a.ex",
               "line" => 51,
               "mutation" => "drop the nil guard",
               "note" => "a test giving nil"
             }

      assert pre["result"] == "pre-existing"
      assert pre["note"] == "in code the diff left"
    end

    test "mutants=n/a keeps its why" do
      assert {:ok, %{"mutants" => %{"n/a" => "only a docstring changed"}}} =
               Checks.parse(["mutants=n/a:only a docstring changed"])
    end

    test "the same place and mutation given twice is kept once, the later one standing" do
      assert {:ok, %{"mutants" => [%{"result" => "killed"}, %{"line" => 3}]}} =
               Checks.parse([
                 "mutant:survived=lib/a.ex:1:flip",
                 "mutant:killed=lib/a.ex:3:drop it",
                 "mutant:killed=lib/a.ex:1:flip"
               ])
    end

    test "a malformed one is refused, saying what is wrong" do
      assert {:error, msg} = Checks.parse(["mutant:maybe=lib/a.ex:1:flip"])
      assert msg =~ "needs its result"
      assert msg =~ "killed|survived|pre-existing"

      assert {:error, msg} = Checks.parse(["mutant:killed=flip the guard"])
      assert msg =~ "needs the file and line it broke"

      assert {:error, msg} = Checks.parse(["mutant:killed=lib/a.ex:abc:flip"])
      assert msg =~ "needs the file and line it broke"

      assert {:error, msg} = Checks.parse(["mutant:survived=lib/a.ex:4"])
      assert msg =~ "needs the mutation it made"

      assert {:error, msg} = Checks.parse(["mutants=n/a"])
      assert msg =~ "`mutants=n/a:<why>`"

      assert {:error, msg} = Checks.parse(["mutants=killed:lib/a.ex:1:x"])
      assert msg =~ "`mutants=n/a:<why>`"

      assert {:error, msg} = Checks.parse(["mutant=lib/a.ex:1:flip"])
      assert msg =~ "needs its result"
    end

    test "n/a beside a mutant is refused, whichever comes first" do
      for lines <- [
            ["mutants=n/a:nothing", "mutant:killed=lib/a.ex:1:flip"],
            ["mutant:killed=lib/a.ex:1:flip", "mutants=n/a:nothing"]
          ] do
        assert {:error, msg} = Checks.parse(lines)
        assert msg =~ "give it or the mutants, not both"
      end
    end
  end

  describe "Checks.parse/1, the map form" do
    test "takes the stored shape back, a mutation with a colon in it included" do
      given = %{
        "mutants" => [
          %{"result" => "killed", "file" => "lib/a.ex", "line" => 4, "mutation" => "{:ok, x}"},
          %{
            result: "survived",
            file: "lib/a.ex",
            line: "8",
            mutation: "return :error",
            note: "a test of the error"
          }
        ]
      }

      assert {:ok, %{"mutants" => [killed, survived]}} = Checks.parse(given)
      assert killed["mutation"] == "{:ok, x}"
      assert survived["line"] == 8
      assert survived["note"] == "a test of the error"

      assert {:ok, %{"mutants" => [^killed, ^survived]}} =
               Checks.parse(%{"mutants" => [killed, survived]})

      assert {:ok, %{"mutants" => %{"n/a" => "renames only"}}} =
               Checks.parse(%{"mutants" => %{"n/a" => "renames only"}})
    end

    test "a malformed one is refused" do
      assert {:error, msg} =
               Checks.parse(%{"mutants" => [%{"result" => "killed", "file" => "lib/a.ex"}]})

      assert msg =~ "needs the file and line"

      assert {:error, msg} =
               Checks.parse(%{
                 "mutants" => [%{"result" => "killed", "file" => "lib/a.ex", "line" => 2}]
               })

      assert msg =~ "needs its `mutation`"

      assert {:error, msg} =
               Checks.parse(%{"mutants" => [%{"result" => "odd", "file" => "a", "line" => 1}]})

      assert msg =~ "needs its result"

      assert {:error, msg} = Checks.parse(%{"mutants" => %{"n/a" => ""}})
      assert msg =~ "a list of mutants"
    end
  end

  describe "failing, blocking and lines" do
    setup do
      {:ok, checks} =
        Checks.parse([
          "mutant:killed=lib/a.ex:42:flip > to >=",
          "mutant:survived=lib/a.ex:51:drop the guard:a test giving nil",
          "mutant:pre-existing=lib/b.ex:9:return ok"
        ])

      %{checks: checks}
    end

    test "only a survivor fails, and blocks an acceptance", %{checks: checks} do
      assert Checks.failing(checks) == ["the surviving mutant at lib/a.ex:51"]
      assert Checks.blocking(checks) == ["the surviving mutant at lib/a.ex:51"]
      assert Checks.failing_result?("survived")

      for r <- ~w(killed pre-existing n/a), do: refute(Checks.failing_result?(r))
      assert Checks.failing(%{"mutants" => %{"n/a" => "x"}}) == []
    end

    test "each shows as a line with its place, mutation and note", %{checks: checks} do
      assert Checks.lines(checks) == [
               {"mutant", "killed", "lib/a.ex:42; flip > to >="},
               {"mutant", "survived", "lib/a.ex:51; drop the guard; a test giving nil"},
               {"mutant", "pre-existing", "lib/b.ex:9; return ok"}
             ]

      assert Checks.lines(%{"mutants" => %{"n/a" => "renames only"}}) ==
               [{"mutants", "n/a", "renames only"}]
    end

    test "a survivor is a rejection's own cause; other failing parts come first", %{
      checks: checks
    } do
      assert Signals.rejection_kind(checks) == {"process", "a surviving mutant"}

      assert Signals.rejection_kind(Map.put(checks, "ask", "misses")) ==
               {"process", "the ask"}

      killed_only = %{"mutants" => [%{"result" => "killed"}]}
      assert Signals.rejection_kind(killed_only) == {"process", "the reason"}
    end
  end

  describe "a verdict with mutants" do
    test "a survivor on a changed line is a rejection naming the mutation and its cause", ctx do
      submit(ctx)

      assert {:ok, card} =
               decide(ctx, "reject", %{
                 "reason" => "No test fails when the guard goes: write one giving nil",
                 "checks" => [
                   "bar:1=ok",
                   "mutant:killed=lib/a.ex:42:flip > to >=",
                   "mutant:survived=lib/a.ex:51:drop the nil guard:a test giving nil"
                 ]
               })

      assert card.verify_state == "rejected"
      assert [%{"result" => "killed"}, %{"result" => "survived"}] = card.verify_checks["mutants"]

      assert last_body(card) =~
               "- mutant: survived — lib/a.ex:51; drop the nil guard; a test giving nil"

      assert [finding] = findings(card)
      assert finding.source == "rejection"
      assert finding.kind == "process"
      assert finding.cause == "rejected: a surviving mutant"
    end

    test "an acceptance can't carry a survivor", ctx do
      submit(ctx)

      assert {:error, :unprocessable_entity, msg} =
               decide(ctx, "accept", %{
                 "checks" => ["bar:1=ok", "mutant:survived=lib/a.ex:51:drop the guard"]
               })

      assert msg =~ "an acceptance can't carry a failing check"
      assert msg =~ "the surviving mutant at lib/a.ex:51"
      assert msg =~ "a surviving mutant is a rejection"
      assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
    end

    test "killed, pre-existing and n/a can each be accepted", ctx do
      submit(ctx)

      assert {:ok, %{verify_state: "accepted"} = card} =
               decide(ctx, "accept", %{
                 "checks" => [
                   "bar:1=ok",
                   "mutant:killed=lib/a.ex:42:flip",
                   "mutant:pre-existing=lib/old.ex:7:return nil:nothing tests the fallback"
                 ]
               })

      assert [finding] = findings(card)
      assert finding.source == "verification"
      assert finding.kind == "process"
      assert finding.cause == "pre-existing mutant lib/old.ex:7"
      assert finding.text =~ "No test fails when lib/old.ex:7 is broken (return nil)"
      assert finding.text =~ "nothing tests the fallback"
      assert finding.text =~ "not a rejection"
    end

    test "n/a is accepted and records no finding", ctx do
      submit(ctx)

      assert {:ok, card} =
               decide(ctx, "accept", %{"checks" => ["bar:1=ok", "mutants=n/a:renames only"]})

      assert card.verify_checks["mutants"] == %{"n/a" => "renames only"}
      assert findings(card) == []
    end

    test "a rejection on a pre-existing survivor alone is refused, and says why", ctx do
      submit(ctx)

      assert {:error, :unprocessable_entity, msg} =
               decide(ctx, "reject", %{
                 "reason" => "weak tests",
                 "checks" => ["mutant:pre-existing=lib/old.ex:7:return nil"]
               })

      assert msg =~ "`mutant:survived=lib/foo.ex:42:<mutation>`"
      assert msg =~ "a mutant surviving, only in code the change didn't touch"
      assert findings(ctx.card) == []
    end

    test "the same pre-existing survivor reported twice is one finding, counted", ctx do
      submit(ctx)

      {:ok, _} =
        decide(ctx, "reject", %{
          "reason" => "bar 1: no",
          "checks" => ["bar:1=fail", "mutant:pre-existing=lib/old.ex:7:return nil"]
        })

      submit(ctx, @second)

      {:ok, card} =
        decide(ctx, "accept", %{
          "checks" => ["bar:1=ok", "mutant:pre-existing=lib/old.ex:7:return nil"]
        })

      assert [%{count: 2}] = card |> findings() |> Enum.filter(&(&1.source == "verification"))
    end
  end

  describe "a resubmission (#1944)" do
    defp reject_with_mutants(ctx) do
      submit(ctx, @first)

      {:ok, card} =
        decide(ctx, "reject", %{
          "reason" => "write the nil test",
          "checks" => [
            "bar:1=ok",
            "mutant:killed=lib/a.ex:42:flip > to >=",
            "mutant:killed=lib/a.ex:60:return []",
            "mutant:survived=lib/a.ex:51:drop the guard"
          ]
        })

      card
    end

    test "carries the killed mutants it didn't judge again; survivors never", ctx do
      reject_with_mutants(ctx)
      submit(ctx, @second)

      {:ok, card} =
        decide(ctx, "accept", %{
          "checks" => [
            "mutant:killed=lib/a.ex:51:drop the guard",
            "mutant:killed=lib/a.ex:60:return the input"
          ]
        })

      mutants = card.verify_checks["mutants"]

      assert %{"result" => "killed", "carried_from" => @first, "mutation" => "flip > to >="} =
               Enum.find(mutants, &(&1["line"] == 42))

      # Judged again at its place (the commits since touched it): stands as judged.
      line60 = Enum.find(mutants, &(&1["line"] == 60))
      assert line60["mutation"] == "return the input"
      refute Map.has_key?(line60, "carried_from")

      assert Enum.count(mutants) == 3
      refute Enum.any?(mutants, &(&1["result"] == "survived"))

      assert {"mutant", "killed", "carried from aaaa111; lib/a.ex:42; flip > to >="} in Checks.lines(
               card.verify_checks
             )
    end

    test "`mutant:carried` takes the killed one at that place; a survivor can't be carried",
         ctx do
      reject_with_mutants(ctx)
      submit(ctx, @second)

      assert {:error, :unprocessable_entity, msg} =
               decide(ctx, "accept", %{"checks" => ["mutant:carried=lib/a.ex:51"]})

      assert msg =~ "the mutant at lib/a.ex:51 didn't pass at aaaa111"

      {:ok, card} =
        decide(ctx, "accept", %{
          "checks" => ["mutant:carried=lib/a.ex:42", "mutant:killed=lib/a.ex:51:drop the guard"]
        })

      assert %{"result" => "killed", "carried_from" => @first} =
               Enum.find(card.verify_checks["mutants"], &(&1["line"] == 42))
    end

    test "n/a this round carries nothing", ctx do
      reject_with_mutants(ctx)
      submit(ctx, @second)

      {:ok, card} = decide(ctx, "accept", %{"checks" => ["mutants=n/a:the change was reverted"]})
      assert card.verify_checks["mutants"] == %{"n/a" => "the change was reverted"}
    end

    test "the prompt lists the killed mutants as passed then", ctx do
      reject_with_mutants(ctx)
      card = submit(ctx, @second)
      prompt = Verified.verify_prompt(card, ctx.board)
      assert prompt =~ "the mutant at lib/a.ex:42, the mutant at lib/a.ex:60."
      refute prompt =~ "the mutant at lib/a.ex:51"
    end
  end
end
