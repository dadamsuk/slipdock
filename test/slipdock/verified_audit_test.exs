defmodule Slipdock.VerifiedAuditTest do
  @moduledoc """
  Spot-checks of accepted work (#1780): with `verify_audit` set to N, about 1
  in N cards an agent accepted is queued for the verify pool again as an
  audit (kind `verify`, `audit: true`), never to the runner that built it or
  the one that verified it. Its prompt shows the original verdict and has
  every rule judged; its decision (`agree` / `disagree`) only comments, and
  a disagreement raises an alert for the board's owner and files the rework
  card (#2632), or comments on the one still open.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Handbook, Repo, Runners, Verified}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job
  alias Slipdock.Verified.Checks

  setup do
    owner = user_fixture("audit-owner@example.com")
    board = board_fixture(%{"name" => "Audits", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "verify_pool" => "loop",
        "verify_audit" => 1
      })

    doing = Enum.find(board.columns, &(&1.category == "doing"))

    runner = fn name ->
      elem(Runners.create_runner(board, %{"name" => name, "pool" => "loop"}), 1)
    end

    %{
      owner: owner,
      board: board,
      doing: doing,
      builder_runner: runner.("builder"),
      verifier_runner: runner.("verifier"),
      third_runner: runner.("third")
    }
  end

  defp agent(ctx, job_id),
    do: Actor.runner(ctx.owner, job_id, "agent")

  defp audits(card),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id and j.audit == true))

  # Built in a job on the builder's runner, submitted, then verified in a
  # job the verifier's runner claims; the decision made from that job.
  defp build_and_verify(ctx, decision \\ "accept", params \\ %{}) do
    card = card_fixture(ctx.doing, %{"title" => "Work #{System.unique_integer([:positive])}"})
    {:ok, work} = Runners.queue(card, %{pool: "loop", kind: "claude", prompt: "Do it"})
    %Job{id: id} = Runners.claim(ctx.builder_runner)
    assert id == work.id

    {:ok, card} =
      Boards.Cards.update_card(card, %{"completed" => true, "evidence" => "ran it"},
        actor: agent(ctx, work.id)
      )

    assert card.verify_state == "pending"
    {:ok, _} = Runners.finish(ctx.builder_runner, work.id, %{status: "done"})

    verify = Runners.claim(ctx.verifier_runner)
    assert verify.kind == "verify" and verify.card_id == card.id and not verify.audit

    {:ok, card} =
      Verified.decide(
        Repo.get!(Card, card.id),
        decision,
        Map.merge(%{"reason" => "checked it", "checks" => ["bar:1=ok"]}, params),
        agent(ctx, verify.id),
        ctx.owner
      )

    {:ok, _} = Runners.finish(ctx.verifier_runner, verify.id, %{status: "done"})
    card
  end

  describe "the sample" do
    test "is about 1 in N, the same for a card every time, and none at 0" do
      hits = Enum.count(1..2000, &Verified.audit_sampled?(&1, 5))
      assert hits in 300..500
      assert Verified.audit_sampled?(17, 5) == Verified.audit_sampled?(17, 5)
      assert Enum.all?(1..50, &Verified.audit_sampled?(&1, 1))
      refute Enum.any?(1..50, &Verified.audit_sampled?(&1, 0))
      refute Verified.audit_sampled?(1, nil)
    end

    test "a sub-board takes its root's setting", ctx do
      epic = card_fixture(ctx.doing, %{"title" => "Epic"})
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      [column | _] = Boards.get_board!(sub.id).columns
      assert Verified.audit_every(card_fixture(column, %{"title" => "Child"})) == 1
    end
  end

  describe "queueing" do
    test "an agent's acceptance in the sample queues an audit the builder and verifier can't take",
         ctx do
      card = build_and_verify(ctx)
      assert card.completed

      assert [audit] = audits(card)
      assert audit.kind == "verify" and audit.pool == "loop" and audit.status == "queued"
      assert audit.exclude_runner_id == ctx.builder_runner.id

      assert Enum.sort(audit.exclude_runner_ids) ==
               Enum.sort([ctx.builder_runner.id, ctx.verifier_runner.id])

      assert Runners.claim(ctx.builder_runner) == nil
      assert Runners.claim(ctx.verifier_runner) == nil
      assert %Job{id: id} = Runners.claim(ctx.third_runner)
      assert id == audit.id
    end

    test "out of the sample, at 0, without a verify pool or after a rejection: none", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"verify_audit" => 0})
      assert audits(build_and_verify(ctx)) == []

      {:ok, _} = Boards.update_board(ctx.board, %{"verify_audit" => 1})
      rejected = build_and_verify(ctx, "reject", %{"checks" => ["bar:1=fail"]})
      assert rejected.verify_state == "rejected"
      assert audits(rejected) == []

      # N large enough that this card isn't sampled.
      n = Enum.find(2..1000, &(not Verified.audit_sampled?(1, &1)))
      assert n
    end

    test "a person's acceptance is never audited", ctx do
      card = card_fixture(ctx.doing, %{"title" => "By hand"})

      {:ok, _} =
        Boards.Cards.update_card(card, %{"completed" => true},
          actor: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.owner.id, agent: "b"}
        )

      {:ok, card} =
        Verified.decide(Repo.get!(Card, card.id), "accept", %{}, Actor.web(ctx.owner), ctx.owner)

      assert card.completed
      assert audits(card) == []
    end

    test "on a pull request board the audit waits for the merge", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"ship_via" => "pull_request"})

      card =
        build_and_verify(ctx, "accept", %{})
        |> then(&Repo.get!(Card, &1.id))

      assert card.verify_state == "merging"
      assert audits(card) == []

      {:ok, card} =
        Verified.decide(card, "merged", %{"commit" => "abc1234"}, Actor.web(ctx.owner), ctx.owner)

      assert card.completed
      assert [_] = audits(card)
    end
  end

  describe "the audit prompt" do
    test "shows the original verdict, judges every rule and decides only agree or disagree",
         ctx do
      {:ok, _} = Handbook.install(ctx.owner, ctx.board)
      card = build_and_verify(ctx, "accept", %{"checks" => ["bar:1=ok", "ask=ok"]})
      [audit] = audits(card)
      prompt = audit.prompt

      assert prompt =~ "Audit card ##{card.id}"
      assert prompt =~ "You are checking the checker"
      assert prompt =~ "You change nothing: not the code, not the card."
      assert prompt =~ "accepted by runner verifier"
      assert prompt =~ "Its reason: checked it"
      assert prompt =~ "- the ask: ok\n- bar 1: ok"
      assert prompt =~ "Judge every rule it lists, `should` rules as well as `must`"
      assert prompt =~ "--paths-from -"
      # A rule the bar asks for is met by a proposal, never an edit (#1882).
      assert prompt =~ Verified.rule_proposal_sentence()
      assert prompt =~ Verified.rule_rejection_sentence()
      assert prompt =~ "A rejection never asks the builder to edit `## Rules` directly"
      assert prompt =~ "--check proposal --json"
      assert prompt =~ "slipdock verify #{card.id} agree --reason"
      assert prompt =~ "slipdock verify #{card.id} disagree --reason"
      refute prompt =~ "verify #{card.id} accept"
      refute prompt =~ "verify #{card.id} reject"
      assert prompt == Verified.audit_prompt(Repo.get!(Card, card.id), ctx.board)
      # A claimed audit keeps its own prompt, as a verify job does.
      assert Runners.claimed_prompt(audit) == prompt
    end

    test "says when the verdict gave no parts", ctx do
      card = build_and_verify(ctx, "accept", %{"checks" => nil, "reason" => ""})
      assert hd(audits(card)).prompt =~ "Its reason: (no reason given)\n(It gave no parts.)"
    end
  end

  describe "the audit's decision" do
    setup ctx do
      card = build_and_verify(ctx)
      [audit] = audits(card)
      %Job{} = Runners.claim(ctx.third_runner)
      %{card: card, audit: audit, auditor: agent(ctx, audit.id)}
    end

    defp alerts(card), do: Repo.all(from(a in Alert, where: a.card_id == ^card.id))

    defp unchanged!(before) do
      now = Repo.get!(Card, before.id)

      for f <- ~w(completed verify_state verify_by verify_note verify_checks column_id evidence)a,
          do: assert(Map.get(now, f) == Map.get(before, f), "#{f} changed")
    end

    test "agree comments and changes nothing else; no alert", ctx do
      before = Repo.get!(Card, ctx.card.id)

      assert {:ok, _} =
               Verified.decide(
                 before,
                 "agree",
                 %{"reason" => "Looked again", "checks" => ["bar:1=ok"]},
                 ctx.auditor,
                 ctx.owner
               )

      unchanged!(before)
      assert alerts(before) == []

      body = Boards.Cards.get_card!(before.id).comments |> Enum.max_by(& &1.id) |> Map.get(:body)
      assert body =~ "**Audit: agrees** with the acceptance, by runner third."
      assert body =~ "Looked again\n\nChecks:\n\n- bar 1: ok"
    end

    test "disagree comments and alerts the board's owner, and the acceptance stands", ctx do
      before = Repo.get!(Card, ctx.card.id)

      assert {:error, :unprocessable_entity, "a disagreement needs its reason"} =
               Verified.decide(before, "disagree", %{}, ctx.auditor, ctx.owner)

      assert {:ok, _} =
               Verified.decide(
                 before,
                 "disagree",
                 %{"reason" => "bar 1: the empty case fails", "checks" => ["bar:1=fail:empty"]},
                 ctx.auditor,
                 ctx.owner
               )

      unchanged!(before)
      assert [alert] = alerts(before)
      assert alert.board_id == ctx.board.id
      assert alert.severity == "warning"
      assert alert.title == "An audit disagrees with the acceptance of ##{before.id}"
      assert alert.body =~ "accepted by runner verifier: bar 1: the empty case fails"
      assert Enum.any?(Automations.list_alerts(ctx.owner), &(&1.id == alert.id))
    end

    test "agree files no rework card", ctx do
      {:ok, _} =
        Verified.decide(Repo.get!(Card, ctx.card.id), "agree", %{}, ctx.auditor, ctx.owner)

      assert Verified.open_rework(ctx.card) == nil
      assert Repo.all(from(c in Card, where: c.caused_by_id == ^ctx.card.id)) == []
    end

    test "disagree files one rework card, named by the alert and the finding", ctx do
      {:ok, card} =
        Boards.Cards.update_card(ctx.card, %{"paths" => ["lib/foo/**", "test/foo/**"]})

      {:ok, _} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "disagree",
          %{
            "reason" => "bar 1: the empty case fails\nand more",
            "checks" => ["bar:1=fail:empty", "ask=ok"]
          },
          ctx.auditor,
          ctx.owner
        )

      assert [rework] = Repo.all(from(c in Card, where: c.caused_by_id == ^card.id))
      assert Verified.open_rework(card).id == rework.id
      assert rework.board_id == card.board_id
      assert rework.title == "Audit of ##{card.id}: bar 1: the empty case fails"
      assert rework.paths == ["lib/foo/**", "test/foo/**"]
      assert rework.priority == "medium"
      # A verification follow-up (#2778).
      assert rework.origin == "verify"
      refute rework.completed
      # The board's ready list, not its backlog: the rework is to be taken up.
      ready = Slipdock.Flow.ready_list(Boards.get_board!(ctx.board.id).columns)
      assert ready.name == "To Do"
      assert rework.column_id == ready.id

      said = Boards.Cards.get_card!(card.id).comments |> Enum.max_by(& &1.id)
      assert said.body =~ "**Audit: disagrees**"
      assert rework.description =~ "An audit disagreed with the acceptance of ##{card.id} "
      assert rework.description =~ "/boards/#{card.board_id}/cards/#{card.id}#comment-#{said.id}"
      assert rework.description =~ "Its reason: bar 1: the empty case fails"
      assert rework.description =~ "What failed:\n\n- bar 1"
      refute rework.description =~ "- the ask\n"
      # It counts as an incident of the accepted card (#1946).
      assert Enum.map(Slipdock.Incidents.caused(card), & &1.id) == [rework.id]

      assert [alert] = alerts(card)
      assert alert.body =~ "Rework filed: ##{rework.id}"

      assert [finding] =
               Repo.all(
                 from(f in Slipdock.Findings.Finding,
                   where: f.card_id == ^card.id and f.source == "audit"
                 )
               )

      assert finding.text =~ "Rework: ##{rework.id}."
    end

    test "a second disagreement comments on the open rework card, never a second one", ctx do
      disagree = fn reason ->
        Verified.decide(
          Repo.get!(Card, ctx.card.id),
          "disagree",
          %{"reason" => reason, "checks" => ["bar:1=fail"]},
          Actor.web(ctx.owner),
          ctx.owner
        )
      end

      {:ok, _} = disagree.("first look")
      rework = Verified.open_rework(ctx.card)
      {:ok, _} = disagree.("second look")

      assert [only] = Repo.all(from(c in Card, where: c.caused_by_id == ^ctx.card.id))
      assert only.id == rework.id

      [comment] = Boards.Cards.get_card!(rework.id).comments
      assert comment.body =~ "**Audit: disagrees again** with the acceptance of ##{ctx.card.id}"
      assert comment.body =~ "second look"
      assert comment.body =~ "- bar 1"

      assert Enum.any?(alerts(ctx.card), &(&1.body =~ "Rework already open: ##{rework.id}"))

      # Once that rework is done, the next disagreement files a new one.
      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, rework.id), %{"completed" => true})
      {:ok, _} = disagree.("third look")
      assert length(Repo.all(from(c in Card, where: c.caused_by_id == ^ctx.card.id))) == 2
      refute Verified.open_rework(ctx.card).id == rework.id
    end

    test "the alert clears itself when its rework is completed (#2691)", ctx do
      {:ok, _} = disagree(ctx, "first look")
      rework = Verified.open_rework(ctx.card)
      assert [alert] = alerts(ctx.card)
      assert alert.body =~ "This alert clears itself once the rework is accepted or completed."

      # Another card's audit alert, and a rule's alert on this card, stay.
      other = build_and_verify(ctx)
      [other_audit] = audits(other)
      %Job{} = Runners.claim(ctx.third_runner)
      {:ok, _} = disagree(ctx, "other look", other, agent(ctx, other_audit.id))

      # Its body even names the rework: only the audit's own title is taken down.
      {:ok, _} =
        Automations.raise_alert(%{
          "board_id" => ctx.board.id,
          "card_id" => ctx.card.id,
          "title" => "A rule's alert",
          "body" => "Noticed\nRework filed: ##{rework.id} “x”."
        })

      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, rework.id), %{"completed" => true})

      assert Enum.map(alerts(ctx.card), & &1.title) == ["A rule's alert"]
      assert [_] = alerts(other)
      refute Repo.get(Alert, alert.id)
    end

    test "a rule's or a person's alert with the audit's own title and rework line stays",
         ctx do
      {:ok, _} = disagree(ctx, "first look")
      rework = Verified.open_rework(ctx.card)
      [audit_alert] = alerts(ctx.card)

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "list_top", "column" => "To Do"},
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        })

      look_alike = %{
        "board_id" => ctx.board.id,
        "card_id" => ctx.card.id,
        "title" => audit_alert.title,
        "body" => "Noticed\nRework filed: ##{rework.id} “x”."
      }

      {:ok, by_rule} = Automations.raise_alert(Map.put(look_alike, "rule_id", rule.id))
      {:ok, for_user} = Automations.raise_alert(Map.put(look_alike, "user_id", ctx.owner.id))

      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, rework.id), %{"completed" => true})

      assert Enum.sort(Enum.map(alerts(ctx.card), & &1.id)) ==
               Enum.sort([by_rule.id, for_user.id])

      refute Repo.get(Alert, audit_alert.id)
    end

    test "a rework accepted by its verifier clears the alert; submitted, it stays", ctx do
      {:ok, _} = disagree(ctx, "first look")
      rework = Verified.open_rework(ctx.card)

      {:ok, rework} =
        Boards.Cards.update_card(rework, %{"completed" => true, "evidence" => "fixed it"},
          actor: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.owner.id, agent: "b"}
        )

      assert rework.verify_state == "pending"
      assert [_] = alerts(ctx.card)

      {:ok, _} =
        Verified.decide(rework, "accept", %{"reason" => "ok"}, Actor.web(ctx.owner), ctx.owner)

      assert alerts(ctx.card) == []
    end

    test "on a pull request board the rework's acceptance (merging) clears it", ctx do
      {:ok, _} = disagree(ctx, "first look")
      rework = Verified.open_rework(ctx.card)
      {:ok, _} = Boards.update_board(ctx.board, %{"ship_via" => "pull_request"})

      {:ok, rework} =
        Boards.Cards.update_card(
          rework,
          %{
            "completed" => true,
            "evidence" => "fixed it",
            "pr" => "https://github.com/example/repo/pull/1",
            "evidence_commit" => "abc1234"
          },
          actor: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.owner.id, agent: "b"}
        )

      assert rework.verify_state == "pending"
      assert [_] = alerts(ctx.card)

      {:ok, rework} =
        Verified.decide(rework, "accept", %{"reason" => "ok"}, Actor.web(ctx.owner), ctx.owner)

      assert rework.verify_state == "merging"
      refute rework.completed
      assert alerts(ctx.card) == []
    end

    test "a disagreement that comments on the open rework leaves the alert; done, both go",
         ctx do
      {:ok, _} = disagree(ctx, "first look")
      rework = Verified.open_rework(ctx.card)
      [first] = alerts(ctx.card)
      {:ok, _} = disagree(ctx, "second look")

      assert Enum.map(alerts(ctx.card), & &1.id) |> Enum.member?(first.id)
      assert length(alerts(ctx.card)) == 2
      [second] = Enum.reject(alerts(ctx.card), &(&1.id == first.id))
      assert second.body =~ "Rework already open: ##{rework.id}"
      assert second.body =~ "This alert clears itself once the rework is accepted or completed."

      {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, rework.id), %{"completed" => true})
      assert alerts(ctx.card) == []
    end

    test "an alert the owner dismissed already: the rework's completion goes without error",
         ctx do
      {:ok, _} = disagree(ctx, "first look")
      rework = Verified.open_rework(ctx.card)
      [alert] = alerts(ctx.card)
      Automations.dismiss_alert(ctx.owner, alert.id)
      assert Automations.list_alerts(ctx.owner) == []

      assert {:ok, %Card{completed: true}} =
               Boards.Cards.update_card(Repo.get!(Card, rework.id), %{"completed" => true})

      assert alerts(ctx.card) == []
      # Nothing left to take down: a second pass is a no-op.
      assert Verified.clear_audit_alerts(Repo.get!(Card, rework.id)) == 0
    end

    test "a card a person names as caused by the accepted one doesn't clear its alert", ctx do
      {:ok, _} = disagree(ctx, "first look")
      ready = Enum.find(ctx.board.columns, &(&1.category == "todo"))

      {:ok, card} =
        Boards.Cards.create_card(ready, %{"title" => "Broke later", "caused_by_id" => ctx.card.id})

      {:ok, _} = Boards.Cards.update_card(card, %{"completed" => true})
      assert [_] = alerts(ctx.card)
      assert Verified.clear_audit_alerts(card) == 0
      assert Verified.clear_audit_alerts(ctx.card) == 0
    end

    test "a card a person names as caused by the accepted one isn't taken for its rework", ctx do
      ready = Enum.find(ctx.board.columns, &(&1.category == "todo"))

      {:ok, _} =
        Boards.Cards.create_card(ready, %{"title" => "Broke later", "caused_by_id" => ctx.card.id})

      assert Verified.open_rework(ctx.card) == nil
    end

    test "is refused from the verifier, from an agent outside the audit job, or on a card not accepted",
         ctx do
      card = Repo.get!(Card, ctx.card.id)

      assert {:error, :forbidden, msg} =
               Verified.decide(card, "agree", %{}, card.verify_by |> to_actor(), ctx.owner)

      assert msg =~ "you accepted card"

      stranger = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: ctx.owner.id, agent: "x"}
      assert {:error, :forbidden, msg} = Verified.decide(card, "agree", %{}, stranger, ctx.owner)
      assert msg =~ "only from its audit job"

      other = card_fixture(ctx.doing, %{"title" => "Not accepted"})

      assert {:error, :conflict, _} =
               Verified.decide(other, "agree", %{}, Actor.web(ctx.owner), ctx.owner)

      # A person may audit at any time.
      assert {:ok, _} = Verified.decide(card, "agree", %{}, Actor.web(ctx.owner), ctx.owner)
    end

    test "a later audit decision on the same card doesn't decide it again", ctx do
      card = Repo.get!(Card, ctx.card.id)
      {:ok, _} = Verified.decide(card, "agree", %{}, ctx.auditor, ctx.owner)

      assert {:error, :conflict, _} =
               Verified.decide(Repo.get!(Card, card.id), "accept", %{}, ctx.auditor, ctx.owner)
    end
  end

  describe "a rework's priority and title" do
    setup ctx do
      %{card: build_and_verify(ctx)}
    end

    test "high for a surviving mutant or a broken must rule, else not" do
      {:ok, survived} = Checks.parse(["mutant:survived=lib/a.ex:3:drop the guard"])
      {:ok, killed} = Checks.parse(["mutant:killed=lib/a.ex:3:drop the guard"])
      {:ok, unknown_rule} = Checks.parse(["rule:UX-4=broken:hex colour"])
      {:ok, bar} = Checks.parse(["bar:1=fail"])

      assert Verified.urgent_disagreement?(survived)
      refute Verified.urgent_disagreement?(killed)
      # A rule the handbook doesn't know counts as a must.
      assert Verified.urgent_disagreement?(unknown_rule)

      assert Verified.urgent_disagreement?(
               Checks.with_severity(unknown_rule, [%{id: "UX-4", severity: "must"}])
             )

      refute Verified.urgent_disagreement?(
               put_in(unknown_rule, ["rules", Access.at(0), "severity"], "should")
             )

      refute Verified.urgent_disagreement?(bar)
      refute Verified.urgent_disagreement?(nil)
    end

    test "the title is the reason's first line, cut to fit", ctx do
      card = ctx.card
      long = String.duplicate("x", 200)
      title = Verified.rework_title(card, long)
      assert String.length(title) == 72
      assert String.ends_with?(title, "…")
      assert Verified.rework_title(card, "  short\nrest") == "Audit of ##{card.id}: short"
    end

    test "a surviving mutant files its rework as high", ctx do
      {:ok, _} =
        Verified.decide(
          Repo.get!(Card, ctx.card.id),
          "disagree",
          %{
            "reason" => "a mutant lives",
            "checks" => [
              "mutant:survived=daemon/ceiling.go:40:flip > to >=:a test at the ceiling"
            ]
          },
          Actor.web(ctx.owner),
          ctx.owner
        )

      rework = Verified.open_rework(ctx.card)
      assert rework.priority == "high"
      assert rework.description =~ "the surviving mutant at daemon/ceiling.go:40"
    end
  end

  defp disagree(ctx, reason, card \\ nil, actor \\ nil) do
    Verified.decide(
      Repo.get!(Card, (card || ctx.card).id),
      "disagree",
      %{"reason" => reason, "checks" => ["bar:1=fail"]},
      actor || Actor.web(ctx.owner),
      ctx.owner
    )
  end

  defp to_actor(map),
    do: %{
      kind: map["kind"],
      via: map["via"],
      user_id: map["user_id"],
      agent: map["agent"],
      job_id: map["job_id"]
    }
end
