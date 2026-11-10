defmodule Slipdock.ReasonShapeTest do
  @moduledoc """
  What agents write onto a card has a shape, not a paragraph (#2692): the
  verify and audit prompts ask for a reason in lines (a first line that
  stands alone, a blank line, one short line per point, the parts in
  `--check`), the claimed builder's prompt asks the same of the evidence,
  and every runner job is told it of its notes and handoffs. A multi-line
  audit reason keeps its line breaks in the audit comment, the rework
  card's description and a comment on a rework still open.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners, Verified}
  alias Slipdock.Automations.Runner
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

  @shape_words [
    "Write the reason as lines, not a paragraph",
    "a first line that stands on its own",
    "a blank line, then one short line per point",
    "The parts go in `--check`, not repeated in the reason"
  ]

  setup do
    owner = user_fixture("shape-owner@example.com")
    board = board_fixture(%{"name" => "Shapes", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "evidence_required" => true,
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
      builder: runner.("builder"),
      verifier: runner.("verifier"),
      third: runner.("third")
    }
  end

  defp agent(ctx, job_id), do: Actor.runner(ctx.owner, job_id, "agent")

  describe "the verify and audit prompts" do
    test "ask for the reason's shape, on stdin, and no longer for prose in an argument", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Shaped"})
      verify = Verified.verify_prompt(card, ctx.board)
      audit = Verified.audit_prompt(card, ctx.board)

      for prompt <- [verify, audit] do
        for words <- @shape_words, do: assert(prompt =~ words)
        assert prompt =~ Verified.reason_shape()
        assert prompt =~ "--reason - <<'EOF'`"
        assert prompt =~ "words on the command line lose them"
        # The example is the shape: a first line, a blank line, a line per point.
        assert prompt =~ "bar 2 fails: the export drops archived cards\n\n       - `Export.run/1`"
      end

      assert verify =~ "slipdock verify #{card.id} accept"
      assert verify =~ "slipdock verify #{card.id} reject"
      assert audit =~ "slipdock verify #{card.id} agree"
      assert audit =~ "slipdock verify #{card.id} disagree"

      # The old invitations to one paragraph are gone.
      refute verify =~ ~s(--reason "what you checked, each check in turn")
      refute verify =~ ~s(--reason "<the check it fails>: what falls short, specifically")
      refute audit =~ ~s(--reason "what you checked")
      refute audit =~ ~s(--reason "where the verdict is wrong, specifically")
    end

    test "a resubmission asks for a line each on what falls short", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Again"})
      {:ok, work} = Runners.queue(card, %{pool: "loop", kind: "claude", prompt: "Do it"})
      %Job{} = Runners.claim(ctx.builder)

      {:ok, card} =
        Boards.update_card(
          card,
          %{"completed" => true, "evidence" => "ran it", "evidence_commit" => "abc1234"},
          actor: agent(ctx, work.id)
        )

      {:ok, _} = Runners.finish(ctx.builder, work.id, %{status: "done"})
      verify = Runners.claim(ctx.verifier)

      {:ok, card} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "reject",
          %{"reason" => "bar 1: no test", "checks" => ["bar:1=fail:none"]},
          agent(ctx, verify.id),
          ctx.owner
        )

      prompt = Verified.verify_prompt(%{card | evidence_commit: "def5678"}, ctx.board)
      assert prompt =~ "This card was judged before"
      assert prompt =~ "say why the fix falls short, a line each in the reason"
      assert prompt =~ Verified.reason_shape()
    end
  end

  describe "the builder's prompt" do
    test "asks for the evidence's shape on a board that asks for evidence", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Evidence"})
      {:ok, job} = Runners.queue(card, %{pool: "loop", kind: "claude", prompt: "Do it"})
      prompt = Runners.claimed_prompt(job)

      assert prompt =~ Verified.evidence_shape()
      assert prompt =~ "write it as lines, not a paragraph"
      assert prompt =~ "the `Handbook:` line and the `Findings:` block on lines of their own"
      assert prompt =~ "not repeated in the text"
      assert prompt =~ "`--evidence - <<'EOF'`"
    end

    test "shows a no-code, an epic's and a spike's evidence on stdin, never one argument", ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"ship_via" => "pull_request", "profiles" => true})

      doing = Enum.find(board.columns, &(&1.category == "doing"))
      card = card_fixture(doing, %{"title" => "Ships by PR"})

      no_code = Verified.no_code_note(card)
      assert no_code =~ ~s(--no-code "<why>" --evidence - <<'EOF'`)
      assert no_code =~ "a first line that stands alone, a blank line, a short line per point"

      epic = Verified.epic_note(card)
      assert epic =~ "slipdock done #{card.id} --suite passed --evidence - <<'EOF'`"
      assert epic =~ "a line per subcard's PR and one for the last merged build"

      spike = Verified.spike_note(card)
      assert spike =~ ~s(prototype on card-#{card.id}" --evidence - <<'EOF'`)
      assert spike =~ "the answer in a line, a blank line, then a line each"

      # What a claimed job is shown carries them, and none as one shell argument.
      {:ok, job} = Runners.queue(card, %{pool: "loop", kind: "claude", prompt: "Do it"})
      prompt = Runners.claimed_prompt(job)
      assert prompt =~ no_code

      for text <- [prompt, no_code, epic, spike] do
        refute text =~ ~s(--evidence "<)
        refute text =~ ~s(--evidence "…")
      end
    end

    test "says nothing of evidence on a board that doesn't ask for it", ctx do
      {:ok, _} =
        Boards.update_board(ctx.board, %{"evidence_required" => false, "verify_work" => false})

      card = card_fixture(ctx.doing, %{"title" => "No evidence"})
      {:ok, job} = Runners.queue(card, %{pool: "loop", kind: "claude", prompt: "Do it"})

      refute Runners.claimed_prompt(job) =~ Verified.evidence_shape()
    end

    test "every runner job is told the shape of its notes, handoffs and status" do
      text = Runner.unattended()
      assert text =~ "a comment, a job-progress note, a handoff, a status"
      assert text =~ "is lines, not a paragraph"
      assert text =~ "a first line that stands on its own"
      assert text =~ "`--message -`"
      assert text =~ "words on the command line lose their line breaks"
    end
  end

  describe "a bare '-' as the reason" do
    setup ctx do
      card = card_fixture(ctx.doing, %{"title" => "Dashed"})
      {:ok, work} = Runners.queue(card, %{pool: "loop", kind: "claude", prompt: "Do it"})
      %Job{} = Runners.claim(ctx.builder)

      {:ok, card} =
        Boards.update_card(
          card,
          %{"completed" => true, "evidence" => "ran it", "evidence_commit" => "abc1234"},
          actor: agent(ctx, work.id)
        )

      {:ok, _} = Runners.finish(ctx.builder, work.id, %{status: "done"})
      %{card: card, verify: Runners.claim(ctx.verifier)}
    end

    test "is refused from an agent, and the card stays pending", ctx do
      for decision <- ~w(reject accept), reason <- ["-", " -\n"] do
        assert {:error, :unprocessable_entity, message} =
                 Verified.decide(
                   Repo.get!(Card, ctx.card.id),
                   decision,
                   %{"reason" => reason, "checks" => ["bar:1=fail:none"]},
                   agent(ctx, ctx.verify.id),
                   ctx.owner
                 )

        assert message =~ "the reason was a bare '-'"
        assert message =~ "the piped reason never arrived"
      end

      card = Repo.get!(Card, ctx.card.id)
      assert card.verify_state == "pending"
      assert card.verify_note == nil
    end

    test "a person is never refused, dash or not", ctx do
      assert {:ok, card} =
               Verified.decide(
                 Repo.get!(Card, ctx.card.id),
                 "reject",
                 %{"reason" => "-"},
                 Actor.web(ctx.owner),
                 ctx.owner
               )

      assert card.verify_state == "rejected"
      assert card.verify_note == "-"
    end

    test "an agent's reason of lines that begin with a dash is kept", ctx do
      reason = "- bar 1: no test\n- bar 2: no docs"

      assert {:ok, card} =
               Verified.decide(
                 Repo.get!(Card, ctx.card.id),
                 "reject",
                 %{"reason" => reason, "checks" => ["bar:1=fail:none"]},
                 agent(ctx, ctx.verify.id),
                 ctx.owner
               )

      assert card.verify_note == reason
    end
  end

  describe "a multi-line audit reason" do
    setup ctx do
      card = card_fixture(ctx.doing, %{"title" => "Audited"})
      {:ok, card} = Boards.update_card(card, %{"paths" => ["lib/foo/**"]})
      {:ok, work} = Runners.queue(card, %{pool: "loop", kind: "claude", prompt: "Do it"})
      %Job{} = Runners.claim(ctx.builder)

      {:ok, card} =
        Boards.update_card(card, %{"completed" => true, "evidence" => "ran it"},
          actor: agent(ctx, work.id)
        )

      {:ok, _} = Runners.finish(ctx.builder, work.id, %{status: "done"})
      verify = Runners.claim(ctx.verifier)

      {:ok, card} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "accept",
          %{"reason" => "checked it", "checks" => ["bar:1=ok"]},
          agent(ctx, verify.id),
          ctx.owner
        )

      [audit] = Repo.all(from(j in Job, where: j.card_id == ^card.id and j.audit == true))
      %Job{} = Runners.claim(ctx.third)
      %{card: card, auditor: agent(ctx, audit.id)}
    end

    @reason """
    bar 1 fails: the empty case crashes

    - `Foo.run/1` matches only a non-empty list
    - no test passes []
    """

    test "a bare '-' is refused, and no rework card is filed", ctx do
      assert {:error, :unprocessable_entity, message} =
               Verified.decide(
                 Repo.get!(Card, ctx.card.id),
                 "disagree",
                 %{"reason" => "-", "checks" => ["bar:1=fail:none"]},
                 ctx.auditor,
                 ctx.owner
               )

      assert message =~ "the reason was a bare '-'"
      refute Repo.exists?(from(c in Card, where: like(c.title, "Audit of #%")))
    end

    test "keeps its line breaks in the comment and the rework card, titled by its first line",
         ctx do
      {:ok, _} =
        Verified.decide(
          Repo.get!(Card, ctx.card.id),
          "disagree",
          %{"reason" => @reason, "checks" => ["bar:1=fail:empty"]},
          ctx.auditor,
          ctx.owner
        )

      kept = String.trim(@reason)

      said = Boards.get_card!(ctx.card.id).comments |> Enum.max_by(& &1.id)
      assert said.body =~ "**Audit: disagrees**"
      assert said.body =~ "**Audit: disagrees** with the acceptance, by runner third.\n\n" <> kept

      assert [rework] = Repo.all(from(c in Card, where: c.caused_by_id == ^ctx.card.id))
      assert rework.title == "Audit of ##{ctx.card.id}: bar 1 fails: the empty case crashes"
      assert rework.description =~ "Its reason: " <> kept

      assert rework.description =~
               "crashes\n\n- `Foo.run/1` matches only a non-empty list\n- no test passes []"

      # Rendered, the points stay a list rather than one paragraph.
      html = SlipdockWeb.RichText.markdown(rework.description) |> Phoenix.HTML.safe_to_string()
      assert html =~ ~r{<li>\s*<code[^>]*>Foo\.run/1</code> matches only a non-empty list\s*</li>}

      # A second disagreement comments on the open rework, its lines kept too.
      {:ok, _} =
        Verified.decide(
          Repo.get!(Card, ctx.card.id),
          "disagree",
          %{"reason" => "still short\n\n- the nil case too", "checks" => ["bar:1=fail:nil"]},
          ctx.auditor,
          ctx.owner
        )

      again = Boards.get_card!(rework.id).comments |> Enum.max_by(& &1.id)
      assert again.body =~ "**Audit: disagrees again**"
      assert again.body =~ "still short\n\n- the nil case too"
    end
  end
end
