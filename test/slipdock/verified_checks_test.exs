defmodule Slipdock.VerifiedChecksTest do
  @moduledoc """
  A verdict in parts (#1778): `Verified.Checks` parses a verifier's checks,
  and `Verified.decide/5` stores them as `verify_checks` (never cast), refuses
  a rejection with no failing part and an acceptance with a broken `must`
  rule, and keeps each verdict in its comment when a later one replaces it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Handbook, Repo, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Verified.Checks

  describe "Checks.parse/1" do
    test "lines, one part each, in the stored shape" do
      assert {:ok, checks} =
               Checks.parse([
                 "ask=ok",
                 "bar:1=ok",
                 "bar:2=fail:no header row",
                 "suite=412:0",
                 ~s(rule:ux-4=broken:"hex in card.ex"),
                 "handbook=disputed:W-3 wasn't edited"
               ])

      assert checks == %{
               "ask" => "ok",
               "bar" => [
                 %{"item" => "1", "result" => "ok"},
                 %{"item" => "2", "result" => "fail", "note" => "no header row"}
               ],
               "suite" => %{"passed" => 412, "failed" => 0},
               "rules" => [%{"id" => "UX-4", "result" => "broken", "note" => "hex in card.ex"}],
               "handbook_line" => "disputed",
               "notes" => %{"handbook_line" => "W-3 wasn't edited"}
             }
    end

    test "a later line for the same item replaces it; blanks and nil are no parts" do
      assert {:ok, %{"bar" => [%{"item" => "1", "result" => "fail"}]}} =
               Checks.parse(["bar:1=ok", "", "bar:1=fail"])

      assert {:ok, %{}} = Checks.parse(nil)
      assert {:ok, %{}} = Checks.parse([])
      assert {:ok, %{"ask" => "misses"}} = Checks.parse("ask=misses\n")
    end

    test "the stored map is taken back as it is" do
      map = %{
        "ask" => "misses",
        "bar" => [%{"item" => 2, "result" => "fail", "note" => "x"}],
        "suite" => %{"passed" => 3, "failed" => 1},
        "rules" => [%{"id" => "arch-3", "result" => "n/a"}],
        "notes" => %{"ask" => "the footer"},
        "from_reason" => true
      }

      assert {:ok, checks} = Checks.parse(map)
      assert checks["bar"] == [%{"item" => "2", "result" => "fail", "note" => "x"}]
      assert checks["rules"] == [%{"id" => "ARCH-3", "result" => "n/a"}]
      assert checks["notes"] == %{"ask" => "the footer"}
      refute Map.has_key?(checks, "from_reason")
    end

    test "what doesn't parse says which part and how it should read" do
      assert {:error, msg} = Checks.parse(["bar 2 fail"])
      assert msg =~ "`bar 2 fail` should read `part=result`"
      assert {:error, msg} = Checks.parse(["bar=fail"])
      assert msg =~ "needs which one: `bar:<n>=…`"
      assert {:error, msg} = Checks.parse(["rule=ok"])
      assert msg =~ "`rule:<id>=…`"
      assert {:error, msg} = Checks.parse(["bar:1=maybe"])
      assert msg =~ "check `bar` is ok, fail, carried, not `maybe`"
      assert {:error, msg} = Checks.parse(["suite=lots"])
      assert msg =~ "`suite=<passed>:<failed>`"
      assert {:error, msg} = Checks.parse(["vibes=ok"])
      assert msg =~ "unknown check `vibes`"
      assert {:error, _} = Checks.parse(%{"suite" => %{"passed" => -1, "failed" => 0}})
      assert {:error, _} = Checks.parse(%{"colour" => "red"})
      assert {:error, _} = Checks.parse(42)
    end
  end

  describe "Checks.from_reason/1, failing/1 and blocking/1" do
    test "a reason's citations are its failing parts" do
      checks =
        Checks.from_reason("bar 2: no header\n- UX-4: hex colour\nthe ask: misses the footer")

      assert checks["bar"] == [%{"item" => "2", "result" => "fail"}]
      assert checks["rules"] == [%{"id" => "UX-4", "result" => "broken"}]
      assert checks["ask"] == "misses"
      assert Checks.from_reason("Handbook line: W-3 not edited")["handbook_line"] == "disputed"
      assert Checks.from_reason("It just doesn't work") == %{}
      assert Checks.from_reason(nil) == %{}
    end

    test "a broken should rule doesn't block an acceptance; anything else failing does" do
      {:ok, checks} = Checks.parse(["bar:1=ok", "rule:UX-9=broken", "suite=3:0"])
      should = Checks.with_severity(checks, [%{id: "UX-9", severity: "should"}])
      must = Checks.with_severity(checks, [%{id: "UX-9", severity: "must"}])

      assert Checks.failing(should) == ["UX-9"]
      assert Checks.blocking(should) == []
      assert Checks.blocking(must) == ["UX-9"]
      # A rule the handbook doesn't know counts as a must.
      assert Checks.blocking(checks) == ["UX-9"]

      {:ok, red} = Checks.parse(["suite=3:1"])
      assert Checks.blocking(red) == ["the suite (1 failed)"]
    end

    test "lines/1 gives the parts in check order" do
      {:ok, checks} =
        Checks.parse(["handbook_line=ok", "rule:A-1=ok", "suite=2:0", "bar:1=fail:x", "ask=ok"])

      assert Checks.lines(checks) == [
               {"the ask", "ok", nil},
               {"bar 1", "fail", "x"},
               {"suite", "2 passed, 0 failed", nil},
               {"A-1", "ok", nil},
               {"Handbook line", "ok", nil}
             ]

      assert Checks.lines(nil) == []
      assert Checks.failing_result?("fail")
      assert Checks.failing_result?("3 passed, 1 failed")
      refute Checks.failing_result?("3 passed, 0 failed")
    end
  end

  describe "Verified.decide/5 with checks" do
    setup do
      owner = user_fixture("checks-owner@example.com")
      board = board_fixture(%{"name" => "Parts", "code" => unique_code()}, owner: owner)
      {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
      doing = Enum.find(board.columns, &(&1.category == "doing"))
      card = card_fixture(doing, %{"title" => "Export"})

      agent = fn label ->
        %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
      end

      builder = agent.("builder")

      {:ok, card} =
        Boards.Cards.update_card(card, %{"completed" => true, "evidence" => "ran it"},
          actor: builder,
          by: owner
        )

      assert card.verify_state == "pending"
      %{owner: owner, board: board, card: card, builder: builder, checker: agent.("checker")}
    end

    defp bodies(card),
      do: Boards.Cards.get_card!(card.id).comments |> Enum.sort_by(& &1.id) |> Enum.map(& &1.body)

    test "a rejection stores its parts and says them on its comment", ctx do
      assert {:ok, card} =
               Verified.decide(
                 ctx.card,
                 "reject",
                 %{"reason" => "Not there yet", "checks" => ["bar:1=ok", "bar:2=fail:no footer"]},
                 ctx.checker,
                 ctx.owner
               )

      assert card.verify_state == "rejected"

      assert card.verify_checks == %{
               "bar" => [
                 %{"item" => "1", "result" => "ok"},
                 %{"item" => "2", "result" => "fail", "note" => "no footer"}
               ]
             }

      assert List.last(bodies(card)) =~
               "Not there yet\n\nChecks:\n\n- bar 1: ok\n- bar 2: fail — no footer"
    end

    test "a rejection with parts but none failing is refused, and changes nothing", ctx do
      assert {:error, :unprocessable_entity, msg} =
               Verified.decide(
                 ctx.card,
                 "reject",
                 %{"reason" => "bar 1: hmm", "checks" => ["bar:1=ok"]},
                 ctx.checker,
                 ctx.owner
               )

      assert msg =~ "a rejection names what fails"
      assert Repo.get!(Card, ctx.card.id).verify_state == "pending"
    end

    test "an agent's rejection with no parts reads them from the reason, or is refused", ctx do
      assert {:error, :unprocessable_entity, msg} =
               Verified.decide(ctx.card, "reject", %{"reason" => "Nope"}, ctx.checker, ctx.owner)

      assert msg =~ "start the reason with the one it fails"
      assert Repo.get!(Card, ctx.card.id).verify_checks == nil

      assert {:ok, card} =
               Verified.decide(
                 ctx.card,
                 "reject",
                 %{"reason" => "the ask: the footer is missing"},
                 ctx.checker,
                 ctx.owner
               )

      assert card.verify_checks == %{"ask" => "misses", "from_reason" => true}
      # The reason already says them: no Checks block.
      refute List.last(bodies(card)) =~ "Checks:"
    end

    test "a person's rejection may stand on its reason alone", ctx do
      assert {:ok, card} =
               Verified.decide(
                 ctx.card,
                 "reject",
                 %{"reason" => "Not what I meant"},
                 Actor.web(ctx.owner),
                 ctx.owner
               )

      assert card.verify_state == "rejected"
      assert card.verify_checks == nil
    end

    test "an unparseable check is refused with what's wrong", ctx do
      assert {:error, :unprocessable_entity, msg} =
               Verified.decide(
                 ctx.card,
                 "accept",
                 %{"checks" => ["bar:1=probably"]},
                 ctx.checker,
                 ctx.owner
               )

      assert msg =~ "check `bar` is ok, fail"
    end

    test "an acceptance with a broken must rule is refused; a broken should is noted", ctx do
      {:ok, _} = Handbook.install(ctx.owner, ctx.board)
      data = Enum.find(Handbook.find(ctx.board).pages, &(&1.title == "Data model"))

      {:ok, _} =
        Slipdock.Wiki.update_page(data, %{
          "front_matter" => "---\nhandbook: data-model\n---\n",
          "body" =>
            "# Data model\n\n## Rules\n\n" <>
              "- **DATA-1** should · judgement · Prefer a new column to a cast.\n" <>
              "- **DATA-2** must · judgement · Never edit a run migration.\n"
        })

      must = %{id: "DATA-2"}
      should = %{id: "DATA-1"}

      assert {:error, :unprocessable_entity, msg} =
               Verified.decide(
                 ctx.card,
                 "accept",
                 %{"checks" => ["bar:1=ok", "rule:#{must.id}=broken"]},
                 ctx.checker,
                 ctx.owner
               )

      assert msg =~ "an acceptance can't carry a failing check: #{must.id}"
      assert Repo.get!(Card, ctx.card.id).verify_state == "pending"

      assert {:ok, card} =
               Verified.decide(
                 ctx.card,
                 "accept",
                 %{"checks" => ["bar:1=ok", "rule:#{should.id}=broken:later"]},
                 ctx.checker,
                 ctx.owner
               )

      assert card.completed

      assert card.verify_checks["rules"] == [
               %{
                 "id" => should.id,
                 "result" => "broken",
                 "severity" => "should",
                 "note" => "later"
               }
             ]
    end

    test "an acceptance can't carry a failing bar item either", ctx do
      assert {:error, :unprocessable_entity, msg} =
               Verified.decide(
                 ctx.card,
                 "accept",
                 %{"checks" => ["bar:2=fail"]},
                 ctx.checker,
                 ctx.owner
               )

      assert msg =~ "bar 2"
    end

    test "a later decision replaces the parts; the earlier stays in its comment", ctx do
      {:ok, _} =
        Verified.decide(
          ctx.card,
          "reject",
          %{"reason" => "First", "checks" => ["bar:1=fail:empty"]},
          ctx.checker,
          ctx.owner
        )

      {:ok, again} =
        Boards.Cards.update_card(
          Repo.get!(Card, ctx.card.id),
          %{"completed" => true, "evidence" => "2"},
          actor: ctx.builder,
          by: ctx.owner
        )

      {:ok, card} =
        Verified.decide(again, "accept", %{"checks" => ["bar:1=ok"]}, ctx.checker, ctx.owner)

      assert card.verify_checks == %{"bar" => [%{"item" => "1", "result" => "ok"}]}
      assert Enum.any?(bodies(card), &(&1 =~ "- bar 1: fail — empty"))
      assert List.last(bodies(card)) =~ "**Accepted**"
    end

    test "a card update can't set the parts", ctx do
      {:ok, card} =
        Boards.Cards.update_card(ctx.card, %{
          "verify_checks" => %{"ask" => "ok"},
          "title" => "Renamed"
        })

      assert card.title == "Renamed"
      assert Repo.get!(Card, card.id).verify_checks == nil
    end
  end
end
