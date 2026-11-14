defmodule Slipdock.VerifiedPaperworkTest do
  @moduledoc """
  Paperwork is noted, not rejected (#3182): when the only failing parts of a
  verdict are the `Handbook:` line or the evidence's format, an agent's
  verdict accepts the card and each gap is kept as a `process` finding
  (source `verification`). Any other failing part still rejects, paperwork
  beside it or not, and a person's rejection stands as given.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Findings.Finding
  alias Slipdock.Verified.Checks

  setup do
    owner = user_fixture("paperwork-owner@example.com")
    board = board_fixture(%{"name" => "Paperwork", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    card = card_fixture(doing, %{"title" => "Export"})

    agent = fn label ->
      %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: label}
    end

    %{owner: owner, card: card, builder: agent.("builder"), checker: agent.("checker")}
  end

  defp submit(ctx) do
    {:ok, card} =
      Boards.Cards.update_card(
        Repo.get!(Card, ctx.card.id),
        %{"completed" => true, "evidence" => "built", "evidence_commit" => "abc1234"},
        actor: ctx.builder,
        by: ctx.owner
      )

    assert card.verify_state == "pending"
    card
  end

  defp decide(ctx, decision, params, actor \\ nil),
    do:
      Verified.decide(
        Repo.get!(Card, ctx.card.id),
        decision,
        params,
        actor || ctx.checker,
        ctx.owner
      )

  defp findings(card),
    do: Repo.all(from(f in Finding, where: f.card_id == ^card.id, order_by: f.id))

  defp bodies(card),
    do: Boards.Cards.get_card!(card.id).comments |> Enum.map(& &1.body)

  describe "Checks" do
    test "the evidence's format is a part, ok or disputed, with a why" do
      assert {:ok, %{"evidence" => "disputed", "notes" => %{"evidence" => "one paragraph"}}} =
               Checks.parse(["evidence=disputed:one paragraph"])

      assert {:ok, %{"evidence" => "ok"}} = Checks.parse(%{"evidence" => "ok"})
      assert {:error, msg} = Checks.parse(["evidence=fail"])
      assert msg =~ "check `evidence` is ok, disputed"
      assert Checks.from_reason("The evidence: findings in prose")["evidence"] == "disputed"

      {:ok, checks} = Checks.parse(["evidence=disputed:one paragraph"])
      assert {"the evidence", "disputed", "one paragraph"} in Checks.lines(checks)
    end

    test "paperwork fails but doesn't block; anything else beside it does" do
      {:ok, paper} = Checks.parse(["bar:1=ok", "handbook_line=disputed", "evidence=disputed"])

      assert Checks.paperwork(paper) == ["the Handbook line", "the evidence's format"]
      assert Checks.failing(paper) == ["the Handbook line", "the evidence's format"]
      assert Checks.blocking(paper) == []
      assert Checks.paperwork_only?(paper)

      {:ok, more} = Checks.parse(["bar:1=fail:no header", "handbook_line=disputed"])
      assert Checks.blocking(more) == ["bar 1"]
      refute Checks.paperwork_only?(more)

      {:ok, clean} = Checks.parse(["bar:1=ok", "handbook_line=ok", "evidence=ok"])
      refute Checks.paperwork_only?(clean)
      refute Checks.paperwork_only?(nil)
    end
  end

  describe "an agent's verdict" do
    test "a rejection naming only the Handbook line accepts, and keeps the gap", ctx do
      card = submit(ctx)

      assert {:ok, decided} =
               decide(ctx, "reject", %{
                 "reason" => "Handbook line: none in the evidence",
                 "checks" => ["bar:1=ok", "handbook_line=disputed:no Handbook line"]
               })

      assert decided.verify_state == "accepted"
      assert decided.completed
      assert decided.verify_rejections in [nil, 0]
      assert decided.verify_checks["decision"] == "accept"
      assert Enum.any?(bodies(card), &(&1 =~ "**Accepted, not rejected:** only paperwork"))

      assert [f] = findings(card)
      assert f.source == "verification"
      assert f.kind == "process"
      assert f.cause == "paperwork: the Handbook line"
      assert f.text =~ "no Handbook line"
    end

    test "a rejection whose reason cites only paperwork accepts too", ctx do
      card = submit(ctx)

      assert {:ok, decided} =
               decide(ctx, "reject", %{
                 "reason" => "The evidence: the findings are one paragraph"
               })

      assert decided.verify_state == "accepted"
      assert [%{cause: "paperwork: the evidence's format"}] = findings(card)
    end

    test "an acceptance may carry paperwork, and each gap is a finding", ctx do
      card = submit(ctx)

      assert {:ok, decided} =
               decide(ctx, "accept", %{
                 "reason" => "checked",
                 "checks" => ["bar:1=ok", "handbook_line=disputed", "evidence=disputed:prose"]
               })

      assert decided.verify_state == "accepted"
      refute Enum.any?(bodies(card), &(&1 =~ "Accepted, not rejected"))

      assert Enum.map(findings(card), & &1.cause) ==
               ["paperwork: the Handbook line", "paperwork: the evidence's format"]
    end

    test "any other failing part still rejects, paperwork beside it or not", ctx do
      for checks <- [
            ["bar:1=fail:no header row"],
            ["bar:1=fail:no header row", "handbook_line=disputed"],
            ["ask=misses:the footer", "evidence=disputed"],
            ["rule:UX-4=broken:hex colour", "handbook_line=disputed"],
            ["suite=10:1", "evidence=disputed"]
          ] do
        submit(ctx)

        assert {:ok, decided} =
                 decide(ctx, "reject", %{"reason" => "falls short", "checks" => checks})

        assert decided.verify_state == "rejected", inspect(checks)
      end

      card = Repo.get!(Card, ctx.card.id)
      assert findings(card) |> Enum.filter(&(&1.source == "verification")) == []
    end

    test "an acceptance carrying a failing part beside paperwork is refused", ctx do
      submit(ctx)

      assert {:error, :unprocessable_entity, msg} =
               decide(ctx, "accept", %{
                 "reason" => "checked",
                 "checks" => ["bar:1=fail:x", "handbook_line=disputed"]
               })

      assert msg =~ "an acceptance can't carry a failing check: bar 1"
    end
  end

  test "a person's rejection for paperwork stands", ctx do
    submit(ctx)
    person = Actor.web(ctx.owner)

    assert {:ok, decided} =
             decide(
               ctx,
               "reject",
               %{"reason" => "Handbook line: add it", "checks" => ["handbook_line=disputed"]},
               person
             )

    assert decided.verify_state == "rejected"
  end

  test "the verify prompt says paperwork is noted, not rejected" do
    s = Verified.Prompts.paperwork_sentence()
    assert s =~ "Paperwork is noted, not rejected"
    assert s =~ "`evidence=disputed:<why>`"
    assert s =~ "Every other failing part still rejects."
  end
end
