defmodule Slipdock.VerifiedAuditTest do
  @moduledoc """
  Spot-checks of accepted work (#1780): with `verify_audit` set to N, about 1
  in N cards an agent accepted is queued for the verify pool again as an
  audit (kind `verify`, `audit: true`), never to the runner that built it or
  the one that verified it. Its prompt shows the original verdict and has
  every rule judged; its decision (`agree` / `disagree`) only comments, and
  a disagreement raises an alert for the board's owner.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Automations, Boards, Handbook, Repo, Runners, Verified}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

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
      Boards.update_card(card, %{"completed" => true, "evidence" => "ran it"},
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
      {:ok, t} = Boards.find_template(nil, "Simple")
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
        Boards.update_card(card, %{"completed" => true},
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

      body = Boards.get_card!(before.id).comments |> Enum.max_by(& &1.id) |> Map.get(:body)
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

  defp to_actor(map),
    do: %{
      kind: map["kind"],
      via: map["via"],
      user_id: map["user_id"],
      agent: map["agent"],
      job_id: map["job_id"]
    }
end
