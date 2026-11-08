defmodule Slipdock.FindingsSignalsTest do
  @moduledoc """
  The findings the system records without asking (W-2310 §Findings,
  `Slipdock.Findings.Signals`): one test per source, through the code that
  sees it, each with its source, card and job; repeats counted; and a board
  without a handbook keeping them all the same.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Findings, Health, Repo, Runners, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Findings.{Finding, Signals}
  alias Slipdock.Runners.Job

  # A health detector with no fix: what it finds is flagged at once.
  defmodule Stalled do
    @behaviour Slipdock.Health.Detector
    def key, do: "stalled"
    def label, do: "Stalled"
    def defaults, do: %{}
    def detect(_ctx, _settings), do: Process.get(:stalled, [])
  end

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Signals"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(doing, %{"title" => "Watched"})

    agent = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    %{owner: owner, board: board, todo: todo, doing: doing, card: card, agent: agent}
  end

  defp findings(card),
    do: Repo.all(from(f in Finding, where: f.card_id == ^card.id, order_by: f.id))

  defp verifying(ctx, attrs \\ %{}) do
    {:ok, board} = Boards.update_board(ctx.board, Map.merge(%{"verify_work" => true}, attrs))
    board
  end

  defp submit(card, actor, attrs \\ %{}) do
    {:ok, card} =
      Boards.update_card(Repo.get!(Card, card.id), Map.put(attrs, "completed", true),
        actor: actor
      )

    assert card.verify_state == "pending"
    card
  end

  describe "a verifier's rejection" do
    setup ctx do
      verifying(ctx)
      checker = %{ctx.agent | agent: "checker"}
      %{checker: checker}
    end

    defp reject(ctx, params) do
      card = submit(ctx.card, ctx.agent)
      {:ok, _} = Verified.decide(card, "reject", params, ctx.checker, ctx.owner)
    end

    test "records the reason, with its kind from the failing part", ctx do
      reject(ctx, %{"reason" => "bar 2: the empty list case fails"})

      assert [%Finding{source: "rejection", kind: "process", cause: "rejected: bar 2"} = f] =
               findings(ctx.card)

      assert f.text =~ "the empty list case fails"
      assert f.board_id == ctx.board.id
    end

    test "a broken rule is a rule finding; a disputed Handbook line, handbook-wrong" do
      assert Signals.rejection_kind(%{"rules" => [%{"id" => "UX-4", "result" => "broken"}]}) ==
               {"rule", "rule UX-4"}

      assert Signals.rejection_kind(%{"handbook_line" => "disputed"}) ==
               {"handbook-wrong", "Handbook line"}

      assert Signals.rejection_kind(%{"ask" => "misses"}) == {"process", "the ask"}
      assert Signals.rejection_kind(nil) == {"process", "the reason"}
    end

    test "the second rejection for the same part counts, a different part doesn't", ctx do
      reject(ctx, %{"reason" => "bar 2: still failing"})
      reject(ctx, %{"reason" => "bar 2: failing again"})
      reject(ctx, %{"reason" => "the ask: the docs were asked for"})

      assert [%{cause: "rejected: bar 2", count: 2, text: text}, %{cause: "rejected: the ask"}] =
               findings(ctx.card)

      assert text =~ "failing again"
    end
  end

  describe "a rejection once the rework is accepted (#2119)" do
    setup ctx do
      verifying(ctx)
      %{checker: %{ctx.agent | agent: "checker"}}
    end

    defp rejected_then_accepted(ctx) do
      card = submit(ctx.card, ctx.agent)

      {:ok, _} =
        Verified.decide(
          card,
          "reject",
          %{"reason" => "bar 2: still failing"},
          ctx.checker,
          ctx.owner
        )

      card = submit(ctx.card, ctx.agent)

      {:ok, _} =
        Verified.decide(card, "reject", %{"reason" => "UX-4: a raw date"}, ctx.checker, ctx.owner)

      assert ctx.card |> findings() |> Enum.count(&(&1.source == "rejection")) == 2

      card = submit(ctx.card, ctx.agent)

      {:ok, accepted} =
        Verified.decide(card, "accept", %{"reason" => "fixed"}, ctx.checker, ctx.owner)

      accepted
    end

    test "accepting dismisses the card's open rejection findings, each with a note", ctx do
      accepted = rejected_then_accepted(ctx)
      assert accepted.verify_state == "accepted"

      for f <- findings(ctx.card) do
        assert %{source: "rejection", status: "dismissed", note: note} = f
        assert note =~ ~r/^the rework was accepted at \d{4}-\d\d-\d\d \d\d:\d\d UTC$/
      end

      assert length(findings(ctx.card)) == 2
    end

    test "other sources, the verifier's notes and other cards' rejections stay open", ctx do
      other = card_fixture(ctx.doing, %{"title" => "Other"})
      {:ok, _} = Signals.rejected(other, "bar 1: no", %{}, ctx.checker)

      {:ok, _} =
        Findings.record(%{
          card: ctx.card,
          source: "timeout",
          kind: "process",
          text: "timed out",
          cause: "t"
        })

      Signals.pre_existing(
        ctx.card,
        %{
          "rules" => [
            %{"id" => "UX-8", "result" => "pre-existing", "file" => "a.ex", "line" => 3}
          ]
        },
        ctx.checker
      )

      {:ok, _} = Boards.add_comment(ctx.card, "- Findings:\n  - gotcha: a lesson", by: ctx.owner)

      rejected_then_accepted(ctx)

      by_source = ctx.card |> findings() |> Enum.group_by(& &1.source, & &1.status)
      assert by_source["rejection"] == ["dismissed", "dismissed"]
      assert by_source["timeout"] == ["open"]
      assert by_source["verification"] == ["open"]
      assert by_source["agent"] == ["open"]
      assert [%{status: "open"}] = findings(other)
    end

    test "a rejection after the acceptance stays open until the next one", ctx do
      accepted = rejected_then_accepted(ctx)

      # Rejected again later (a failed merge sends a card back, say).
      {:ok, again} =
        Signals.rejected(accepted, "the ask: the docs", %{"ask" => "misses"}, ctx.checker)

      assert again.status == "open"

      # Saving the card while it stays accepted closes nothing.
      {:ok, _} = Boards.update_card(Repo.get!(Card, ctx.card.id), %{"title" => "Renamed"})
      assert Repo.get!(Finding, again.id).status == "open"

      # The next acceptance does.
      assert Signals.accepted(accepted) == 1
      assert Repo.get!(Finding, again.id).status == "dismissed"
      assert Signals.accepted(accepted) == 0
    end

    test "merging, on a board that ships by pull request, is an acceptance too", ctx do
      card = submit(ctx.card, ctx.agent)

      {:ok, _} =
        Verified.decide(card, "reject", %{"reason" => "bar 1: no"}, ctx.checker, ctx.owner)

      card = Repo.get!(Card, ctx.card.id)

      Verified.saved(card, %{card | verify_state: "merging"}, ctx.owner)
      assert [%{status: "dismissed"}] = findings(ctx.card)
    end

    test "the rules tally slipdock quality --rules gives is unchanged", ctx do
      card = submit(ctx.card, ctx.agent)

      {:ok, _} =
        Verified.decide(
          card,
          "reject",
          %{
            "reason" => "UX-4: a raw date",
            "checks" => ["rule:UX-4=broken"]
          },
          ctx.checker,
          ctx.owner
        )

      before = Slipdock.Quality.for_board(ctx.board).rejections
      assert [%{id: "UX-4"} | _] = before.by_rule
      card = submit(ctx.card, ctx.agent)
      {:ok, _} = Verified.decide(card, "accept", %{"reason" => "fixed"}, ctx.checker, ctx.owner)

      assert [%{status: "dismissed"}] = findings(ctx.card)
      assert Slipdock.Quality.for_board(ctx.board).rejections == before
    end
  end

  describe "a runner job that goes wrong" do
    setup ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})
      {:ok, job} = Runners.queue(ctx.card, %{pool: "loop", kind: "claude", prompt: "go"})
      %Job{} = Runners.claim(runner)
      %{runner: runner, job: job}
    end

    test "a timeout is a finding on its card, with its job", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{status: "timeout"})

      assert [%Finding{source: "timeout", cause: "claude job timed out", job_id: job_id} = f] =
               findings(ctx.card)

      assert job_id == ctx.job.id
      assert f.text == "Runner job ##{ctx.job.id} (claude) timed out."
    end

    test "a failure says why; a done or cancelled job is no finding", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "3"})
      assert [%Finding{source: "failed", text: text}] = findings(ctx.card)
      assert text =~ "failed, exit 3"

      {:ok, again} = Runners.queue(ctx.card, %{pool: "loop", kind: "claude", prompt: "go"})
      %Job{} = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, again.id, %{exit: "0"})
      assert [%{count: 1}] = findings(ctx.card)
    end

    test "three timeouts on one card are one finding counted three times", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{status: "timeout"})

      for _ <- 1..2 do
        {:ok, job} = Runners.queue(ctx.card, %{pool: "loop", kind: "claude", prompt: "go"})
        %Job{} = Runners.claim(ctx.runner)
        {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "timeout"})
      end

      assert [%Finding{count: 3}] = findings(ctx.card)
    end

    test "the same job's end heard twice counts once", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{status: "timeout"})
      Signals.job_ended(Repo.get!(Job, ctx.job.id))
      assert [%Finding{count: 1}] = findings(ctx.card)
    end
  end

  describe "a card requeued, or given up on" do
    test "each put-back is counted, and giving up is its own finding", ctx do
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "list_top", "column" => "To Do"},
          "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 1}]
        })

      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})
      a = card_fixture(ctx.todo, %{"title" => "Fed"})
      Slipdock.Automations.feed_rule(rule)

      for _ <- 1..2 do
        job = Runners.claim(runner)
        assert job.card_id == a.id
        :ok = Boards.move_card_to_index(Repo.get!(Card, a.id), ctx.doing, :top)
        {:ok, _} = Runners.finish(runner, job.id, %{status: "done"})
      end

      assert [requeued, gave_up] = Enum.filter(findings(a), &(&1.source == "requeue"))
      assert requeued.cause == "requeued" and requeued.count == 1
      assert requeued.text =~ "put back"
      assert gave_up.cause == "gave up" and gave_up.text =~ "flagged blocked"
      assert is_integer(gave_up.job_id)
    end
  end

  describe "a lane refusal" do
    # A refusal is the lanes working, not a stumble (#1968): it is still
    # refused, with its words, and nothing is recorded.
    test "an agent moving into a lane in use is refused, and is no finding", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true})
      {:ok, _} = Boards.update_card(ctx.card, %{"paths" => ["lib/a/**"]})
      # Only a card a runner job is working on holds its lane (#1922).
      working_job_fixture(ctx.card)
      mine = card_fixture(ctx.todo, %{"title" => "Mine"})
      {:ok, mine} = Boards.update_card(mine, %{"paths" => ["lib/a/b.ex"]})

      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(mine.id, ctx.doing.id, nil, actor: ctx.agent)

      assert message =~ "this board keeps agents in lanes"
      assert message =~ "##{ctx.card.id}"
      assert Repo.reload!(mine).column_id == ctx.todo.id
      assert findings(mine) == []
      assert findings(ctx.card) == []
      refute Repo.exists?(from f in Finding, where: f.source == "lane")
    end

    test "an agent widening its paths onto another card's is refused, and is no finding",
         ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"lanes" => true})
      {:ok, _} = Boards.update_card(ctx.card, %{"paths" => ["lib/a/**"]})
      # Only a card a runner job is working on holds its lane (#1922).
      working_job_fixture(ctx.card)
      mine = card_fixture(ctx.doing, %{"title" => "Mine"})

      assert {:error, _} =
               Boards.update_card(mine, %{"paths" => ["lib/a/c.ex"]}, actor: ctx.agent)

      assert Repo.reload!(mine).paths == []
      assert findings(mine) == []
      refute Repo.exists?(from f in Finding, where: f.source == "lane")
    end

    test "the API guide no longer lists lane among the sources the server records" do
      guide = SlipdockWeb.APIGuide.markdown() |> String.replace(~r/\s+/, " ")

      [_, sources] = Regex.run(~r/The server also records its own \(([^)]*)\)/, guide)
      assert sources =~ "`rejection`"
      assert sources =~ "`health`"
      refute sources =~ "`lane`"
      assert guide =~ "A lane refusal is not one (#1968)"
      assert guide =~ "Findings with source `lane` from before then are kept."
    end
  end

  describe "a failed merge" do
    test "is a tooling finding with the merge job's reason", ctx do
      verifying(ctx, %{"ship_via" => "pull_request"})
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "m", "pool" => "loop"})
      runner = Runners.report_kinds(runner, "claude,merge")

      Repo.update_all(from(r in Runners.Runner, where: r.id == ^runner.id),
        set: [last_seen_at: DateTime.utc_now(:second)]
      )

      card =
        submit(ctx.card, ctx.agent, %{
          "evidence_pr" => "https://github.com/acme/app/pull/1",
          "evidence_commit" => "abc1234"
        })

      {:ok, card} =
        Verified.decide(card, "accept", %{}, %{ctx.agent | agent: "checker"}, ctx.owner)

      assert card.verify_state == "merging"
      %Job{kind: "merge"} = job = Runners.claim(Repo.get!(Runners.Runner, runner.id))

      {:ok, _} =
        Runners.finish(Repo.get!(Runners.Runner, runner.id), job.id, %{
          exit: "1",
          output: "merge: the pull request has a failing check\n"
        })

      assert [%Finding{source: "merge", kind: "tooling", job_id: job_id, text: text}] =
               findings(ctx.card)

      assert job_id == job.id
      assert text =~ "failing check"
    end
  end

  describe "an audit that disagrees" do
    test "is a finding; one that agrees isn't", ctx do
      verifying(ctx)

      {:ok, card} =
        ctx.card
        |> Ecto.Changeset.change(
          verify_state: "accepted",
          verify_by: %{"kind" => "agent", "agent" => "checker", "user_id" => ctx.owner.id}
        )
        |> Repo.update()

      person = Actor.web(ctx.owner)
      {:ok, _} = Verified.decide(card, "agree", %{"reason" => "fine"}, person, ctx.owner)
      assert findings(card) == []

      {:ok, _} =
        Verified.decide(card, "disagree", %{"reason" => "bar 1 wasn't met"}, person, ctx.owner)

      assert [%Finding{source: "audit", text: text}] = findings(card)
      assert text =~ "bar 1 wasn't met"
    end
  end

  describe "a health-monitor flag" do
    defp stalled(card) do
      %{
        subject: %{"card" => card && card.id},
        card_id: card && card.id,
        state: 1,
        summary: "nobody is moving it",
        data: %{}
      }
    end

    test "is a finding on the card, or on the root board with no card", ctx do
      Process.put(:stalled, [stalled(ctx.card), stalled(nil)])
      {:ok, %{"flagged" => 2}} = Health.run(Boards.get_board!(ctx.board.id), detectors: [Stalled])

      assert [%Finding{source: "health", cause: "health: stalled", text: text}] =
               findings(ctx.card)

      assert text == "Stalled: nobody is moving it"

      assert [%Finding{card_id: nil, source: "health"}] =
               Repo.all(
                 from(f in Finding, where: f.board_id == ^ctx.board.id and is_nil(f.card_id))
               )
    end
  end

  describe "a board without a handbook" do
    test "keeps them on its root board, from a subcard too", ctx do
      refute Slipdock.Handbook.find(ctx.board)
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      child = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Child"})

      {:ok, f} = Findings.record(%{card: child, source: "timeout", cause: "x", text: "timed out"})
      assert f.board_id == ctx.board.id
      assert {:ok, [_]} = Findings.list(Boards.get_board!(sub.id))
    end
  end

  test "a finding that can't be written is logged and dropped, never raised", ctx do
    gone = %Card{id: -1, board_id: ctx.board.id, title: "Gone", paths: []}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok == Signals.audit_disagreed(gone, "wrong", nil)
      end)

    assert log =~ "finding not recorded (audit)"
  end
end
