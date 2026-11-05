defmodule Slipdock.VerifiedGateTest do
  @moduledoc """
  The verify gate end to end (epic #1776, W-2310 §The gate), across its four
  parts on one handbook board: the verify prompt's four checks (#1777), a
  verdict in parts (#1778), the rejection past the limit going to a person
  (#1779), and an audit of the acceptance (#1780).
  """
  use Slipdock.DataCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Handbook, Repo, Runners, Verified, Wiki}
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("gate-owner@example.com")
    board = board_fixture(%{"name" => "Gate", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "verify_pool" => "loop",
        "verify_rejection_limit" => 1,
        "verify_audit" => 1
      })

    {:ok, _} = Handbook.install(owner, board)
    data = Enum.find(Handbook.find(board).pages, &(&1.title == "Data model"))

    {:ok, _} =
      Wiki.update_page(data, %{
        "front_matter" => "---\nhandbook: data-model\n---\n",
        "body" =>
          "# Data model\n\n## Rules\n\n" <>
            "- **DATA-1** should · judgement · Prefer a new column to a cast.\n" <>
            "- **DATA-2** must · judgement · Never edit a run migration.\n"
      })

    runner = fn name ->
      {:ok, r, _} = Runners.create_runner(board, %{"name" => name, "pool" => "loop"})
      r
    end

    doing = Enum.find(board.columns, &(&1.category == "doing"))

    card =
      card_fixture(doing, %{
        "title" => "Export",
        "description" => "Add a header row and a footer to the export.",
        "bar" => "1. A header row.\n2. A footer."
      })

    %{
      owner: owner,
      board: board,
      doing: doing,
      card: card,
      builder: runner.("builder"),
      verifier: runner.("verifier"),
      auditor: runner.("auditor")
    }
  end

  defp agent(ctx, job), do: Actor.runner(ctx.owner, job.id, "agent")

  # A build in a job the builder's runner holds, then the verify job the
  # verifier's runner claims.
  defp submit(ctx) do
    {:ok, work} =
      Runners.queue(Repo.get!(Card, ctx.card.id), %{pool: "loop", kind: "claude", prompt: "Do"})

    %Job{} = Runners.claim(ctx.builder)

    {:ok, _} =
      Boards.update_card(
        Repo.get!(Card, ctx.card.id),
        %{
          "completed" => true,
          "evidence" => "Handbook: updated W-1944 §Exports",
          "evidence_commit" => "abc1234"
        },
        actor: agent(ctx, work)
      )

    {:ok, _} = Runners.finish(ctx.builder, work.id, %{status: "done"})
    verify = Runners.claim(ctx.verifier)
    assert verify.kind == "verify" and not verify.audit
    verify
  end

  test "parts, a person past the limit, and an audit that disagrees", ctx do
    # 1. The verify prompt has the four checks, with the rules for the diff.
    verify = submit(ctx)
    assert verify.prompt =~ "What the card asks (its description):\nAdd a header row and a footer"

    assert verify.prompt =~
             ~r/3\. The ask\..*4\. The bar\..*5\. The rules\..*6\. The Handbook line\./s

    assert verify.prompt =~ "slipdock handbook #{ctx.board.code} --paths-from -"

    # 2. A rejection in parts; one naming no failing part is refused.
    assert {:error, :unprocessable_entity, _} =
             Verified.decide(
               Repo.get!(Card, ctx.card.id),
               "reject",
               %{"reason" => "Hmm", "checks" => ["bar:1=ok"]},
               agent(ctx, verify),
               ctx.owner
             )

    {:ok, card} =
      Verified.decide(
        Repo.get!(Card, ctx.card.id),
        "reject",
        %{
          "reason" => "bar 2: no footer",
          "checks" => ["ask=ok", "bar:1=ok", "bar:2=fail:no footer"]
        },
        agent(ctx, verify),
        ctx.owner
      )

    {:ok, _} = Runners.finish(ctx.verifier, verify.id, %{status: "done"})
    assert card.verify_checks["bar"] |> Enum.map(& &1["result"]) == ["ok", "fail"]
    assert Repo.get_by(Boards.Wait, card_id: card.id) == nil

    # 3. The second rejection is past the limit of 1: a person decides.
    verify = submit(ctx)

    {:ok, _} =
      Verified.decide(
        Repo.get!(Card, ctx.card.id),
        "reject",
        %{"reason" => "DATA-2: edits a run migration", "checks" => ["rule:DATA-2=broken"]},
        agent(ctx, verify),
        ctx.owner
      )

    {:ok, _} = Runners.finish(ctx.verifier, verify.id, %{status: "done"})
    card = Repo.get!(Card, ctx.card.id)
    assert "waiting" in card.flags
    assert [%{"id" => "DATA-2", "severity" => "must"}] = card.verify_checks["rules"]

    # A person accepts it as is: no agent verdict, so no audit.
    {:ok, _} = Boards.answer_wait(card, Actor.web(ctx.owner), %{"choice" => 2})
    card = Repo.get!(Card, ctx.card.id)
    assert card.completed and card.verify_state == "accepted"
    assert Repo.all(from(j in Job, where: j.card_id == ^card.id and j.audit)) == []
  end

  test "an agent's acceptance is audited by a third runner, whose disagreement alerts", ctx do
    verify = submit(ctx)

    # A broken must rule can't be accepted; a missed should can, noted.
    assert {:error, :unprocessable_entity, msg} =
             Verified.decide(
               Repo.get!(Card, ctx.card.id),
               "accept",
               %{"checks" => ["bar:1=ok", "bar:2=ok", "rule:DATA-2=broken"]},
               agent(ctx, verify),
               ctx.owner
             )

    assert msg =~ "DATA-2"

    {:ok, card} =
      Verified.decide(
        Repo.get!(Card, ctx.card.id),
        "accept",
        %{
          "reason" => "All there",
          "checks" => ["ask=ok", "bar:1=ok", "bar:2=ok", "rule:DATA-1=broken:later"]
        },
        agent(ctx, verify),
        ctx.owner
      )

    {:ok, _} = Runners.finish(ctx.verifier, verify.id, %{status: "done"})
    assert card.completed

    # 4. The audit: not to the builder or the verifier.
    assert Runners.claim(ctx.builder) == nil
    assert Runners.claim(ctx.verifier) == nil
    audit = Runners.claim(ctx.auditor)
    assert audit.audit and audit.card_id == card.id

    assert audit.prompt =~ "- DATA-1 should: broken — later"

    {:ok, _} =
      Verified.decide(
        Repo.get!(Card, card.id),
        "disagree",
        %{"reason" => "bar 2: the footer is empty", "checks" => ["bar:2=fail"]},
        agent(ctx, audit),
        ctx.owner
      )

    # The acceptance stands; the owner is alerted.
    after_audit = Repo.get!(Card, card.id)
    assert after_audit.completed and after_audit.verify_state == "accepted"
    assert after_audit.verify_checks == card.verify_checks

    assert [%Alert{severity: "warning"}] =
             Repo.all(from(a in Alert, where: a.card_id == ^card.id))
  end
end
