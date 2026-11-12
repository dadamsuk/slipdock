defmodule Slipdock.Health.FinishingDetectorsTest do
  @moduledoc """
  The health monitor's detectors for verification and merges (W-2310,
  #1763): verify_missing, merge_missing, merge_failing and verify_slow, each
  against its case and its near miss; re-queued jobs go to the right pool
  and never to the card's builder.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Health, Repo, Runners}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Health.{Context, Incident, Settings}
  alias Slipdock.Health.Detectors.{HungJob, MergeFailing, MergeMissing, VerifyMissing, VerifySlow}
  alias Slipdock.Runners.{Job, Runner}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Finish"}, owner: owner)

    Repo.update_all(from(b in Board, where: b.id == ^board.id),
      set: [verify_work: true, verify_pool: "verify", ship_via: "pull_request"]
    )

    board = Boards.get_board!(board.id)
    [_backlog, _todo, doing, _done] = board.columns
    {:ok, builder, _} = Runners.create_runner(board, %{"name" => "builder", "pool" => "verify"})
    {:ok, checker, _} = Runners.create_runner(board, %{"name" => "checker", "pool" => "verify"})
    card = card_fixture(doing, %{"title" => "Shipped"})
    %{owner: owner, board: board, doing: doing, card: card, builder: builder, checker: checker}
  end

  defp now, do: DateTime.utc_now(:second)
  defp ago(minutes), do: DateTime.add(now(), -minutes * 60)

  defp detect(detector, board, changes \\ %{}) do
    detector.detect(
      Context.new(board, now()),
      Settings.for(%{detector.key() => changes}, detector)
    )
  end

  defp set_card(card, attrs),
    do: Repo.update_all(from(c in Card, where: c.id == ^card.id), set: attrs)

  defp job(card, attrs) do
    Repo.insert!(
      struct(
        %Job{
          board_id: card.board_id,
          root_board_id: card.board_id,
          card_id: card.id,
          pool: "verify",
          kind: "verify",
          prompt: "",
          status: "queued"
        },
        attrs
      )
    )
  end

  defp incidents(board),
    do: Repo.all(from(i in Incident, where: i.board_id == ^board.id, order_by: i.id))

  describe "verify_missing" do
    test "pending 15 minutes with no verify job open is found; the last job's end is named",
         ctx do
      set_card(ctx.card, verify_state: "pending", verify_at: ago(30))
      old = job(ctx.card, status: "cancelled", finished_at: ago(15))

      assert [f] = detect(VerifyMissing, ctx.board)
      assert f.card_id == ctx.card.id

      assert f.summary =~
               "has waited 15 minutes for verification with no verify job open in pool verify"

      assert f.summary =~ "(the last, ##{old.id}, ended cancelled)"
    end

    test "near misses: a verify job open, only 5 minutes, no verify pool, not pending", ctx do
      set_card(ctx.card, verify_state: "pending", verify_at: ago(30))
      open = job(ctx.card, status: "queued")
      assert detect(VerifyMissing, ctx.board) == []

      Repo.delete!(open)
      set_card(ctx.card, verify_at: ago(5))
      assert detect(VerifyMissing, ctx.board) == []
      assert [_] = detect(VerifyMissing, ctx.board, %{"minutes" => 5})

      set_card(ctx.card, verify_at: ago(30))
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id), set: [verify_pool: nil])
      assert detect(VerifyMissing, ctx.board) == []

      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [verify_pool: "verify"]
      )

      set_card(ctx.card, verify_state: "accepted")
      assert detect(VerifyMissing, ctx.board) == []
    end

    test "the fix queues it again to the verify pool, never to the builder; twice, then flags",
         ctx do
      set_card(ctx.card, verify_state: "pending", verify_at: ago(30))
      # The builder took the card's work job.
      job(ctx.card,
        kind: "claude",
        pool: "dev",
        status: "done",
        runner_id: ctx.builder.id,
        finished_at: ago(31)
      )

      assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [VerifyMissing])

      assert [%Job{pool: "verify", status: "queued", exclude_runner_id: excluded} = first] =
               Repo.all(from(j in Job, where: j.card_id == ^ctx.card.id and j.kind == "verify"))

      assert excluded == ctx.builder.id

      # It is cancelled; the second fix, then the flag.
      Repo.update_all(from(j in Job, where: j.id == ^first.id),
        set: [status: "cancelled", finished_at: ago(11)]
      )

      assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [VerifyMissing])

      Repo.update_all(from(j in Job, where: j.card_id == ^ctx.card.id and j.status == "queued"),
        set: [status: "failed", finished_at: ago(11)]
      )

      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [VerifyMissing])
      assert "stuck" in Repo.get!(Card, ctx.card.id).flags
    end
  end

  describe "verify_missing: a refusal that would come again (#2705)" do
    test "is flagged at once, with the reason, and not retried", ctx do
      set_card(ctx.card, verify_state: "pending", verify_at: ago(30))
      # A pool that isn't a name: every queue of it is refused the same way.
      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [verify_pool: "Bad Pool"]
      )

      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [VerifyMissing])

      card = Repo.get!(Card, ctx.card.id)
      assert "stuck" in card.flags
      assert [incident] = incidents(ctx.board)
      assert incident.status == "flagged"
      assert incident.attempts == 0

      [body] =
        Repo.all(
          from(c in Slipdock.Boards.Comment,
            where: c.card_id == ^card.id and like(c.body, "**Health monitor: stuck**%"),
            select: c.body
          )
        )

      assert body =~ "Couldn't queue a verify job: pool “bad pool” must be lower case"

      assert body =~
               "Queueing it again would be refused the same way. Flagged `stuck` for a person."

      refute body =~ "Tried"
      assert Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "verify")) == []
    end

    test "the resolve says no fix for a lasting refusal, and tries again after one that clears",
         ctx do
      set_card(ctx.card, verify_state: "pending", verify_at: ago(30))

      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [verify_pool: "Bad Pool"]
      )

      assert {:no_fix, why} = VerifyMissing.resolve(%{data: %{"card" => ctx.card.id}}, 1)
      assert why =~ "refused the same way"

      Repo.update_all(from(b in Board, where: b.id == ^ctx.board.id),
        set: [verify_pool: "verify"]
      )

      assert {:fixed, _} = VerifyMissing.resolve(%{data: %{"card" => ctx.card.id}}, 1)
    end

    test "which refusals last" do
      max = Runners.limits().max_prompt

      assert Runners.lasting_refusal?("the prompt is over #{max} bytes")

      assert Runners.lasting_refusal?(
               "pool “Bad Pool” must be lower case letters, digits, - or _"
             )

      assert Runners.lasting_refusal?("kind “X” must be lower case letters, digits, - or _")

      refute Runners.lasting_refusal?(
               "the queue is full: 200 jobs are already waiting or running on this board"
             )

      refute Runners.lasting_refusal?("held back: over 60 jobs queued this minute")
      refute Runners.lasting_refusal?("the prompt is over 1 bytes")
      refute Runners.lasting_refusal?(nil)
    end
  end

  describe "merge_missing" do
    setup ctx do
      Repo.update_all(from(r in Runner, where: r.id == ^ctx.checker.id),
        set: [kinds: ["verify", "merge"], last_seen_at: ago(60), pool: "loop"]
      )

      :ok
    end

    test "merging 20 minutes with no merge job open is found", ctx do
      set_card(ctx.card, verify_state: "merging", verify_at: ago(20))
      assert [f] = detect(MergeMissing, ctx.board)

      assert f.summary =~
               "was accepted 20 minutes ago and shows as merging, but no merge job is open"

      assert f.summary =~ "(none was ever queued)"
    end

    test "near misses: a merge job running, accepted 5 minutes ago, completed", ctx do
      set_card(ctx.card, verify_state: "merging", verify_at: ago(20))
      running = job(ctx.card, kind: "merge", pool: "loop", status: "running")
      assert detect(MergeMissing, ctx.board) == []

      Repo.delete!(running)
      set_card(ctx.card, verify_at: ago(5))
      assert detect(MergeMissing, ctx.board) == []

      set_card(ctx.card, verify_at: ago(20), completed: true)
      assert detect(MergeMissing, ctx.board) == []
    end

    test "the fix queues the merge through merge_pool, to the merge runner's pool", ctx do
      set_card(ctx.card, verify_state: "merging", verify_at: ago(20))
      assert {:ok, %{"fixed" => 1}} = Health.run(ctx.board, detectors: [MergeMissing])

      assert [%Job{kind: "merge", pool: "loop", status: "queued"}] =
               Repo.all(from(j in Job, where: j.card_id == ^ctx.card.id))

      assert List.last(hd(incidents(ctx.board)).log)["what"] =~ "queued merge job #"
    end

    test "with no runner that merges, it is flagged", ctx do
      Repo.update_all(from(r in Runner, where: r.id == ^ctx.checker.id), set: [kinds: ["verify"]])
      set_card(ctx.card, verify_state: "merging", verify_at: ago(20))
      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [MergeMissing])
    end
  end

  describe "merge_failing" do
    test "two failed merges, the last one latest, are flagged with their reasons", ctx do
      job(ctx.card, kind: "merge", status: "failed", error: "conflict in mix.lock")
      last = job(ctx.card, kind: "merge", status: "failed", error: "checks red")

      assert [f] = detect(MergeFailing, ctx.board)
      assert f.state == last.id
      assert f.summary =~ "has failed 2 times, most recently job ##{last.id}"
      assert f.summary =~ "conflict in mix.lock"
      assert f.summary =~ "checks red"

      assert {:ok, %{"flagged" => 1}} = Health.run(ctx.board, detectors: [MergeFailing])
      assert "stuck" in Repo.get!(Card, ctx.card.id).flags
    end

    test "a card sent back rejected is looping between accepted and rejected", ctx do
      set_card(ctx.card, verify_state: "rejected")
      job(ctx.card, kind: "merge", status: "failed", error: "conflict in mix.lock")
      job(ctx.card, kind: "merge", status: "failed", error: "checks red")

      assert [f] = detect(MergeFailing, ctx.board)
      assert f.summary =~ "it is looping between accepted and rejected"
      refute f.summary =~ "still merging"
    end

    # #2759: a merge that found the pull request already merged isn't a
    # failing merge; merge_missing flags the card once instead.
    test "already-merged failures aren't counted as failing merges", ctx do
      set_card(ctx.card, verify_state: "merging")

      for said <- [
            "merge: #9 was already merged at head abc1234, not the accepted commit 1a2b",
            "merge: #9 is MERGED, not open; nothing merged"
          ] do
        job(ctx.card, kind: "merge", status: "failed", output: "x\n" <> said)
      end

      job(ctx.card, kind: "merge", status: "failed", output: "merge: #9 is MERGED, not open")
      assert detect(MergeFailing, ctx.board) == []

      # One real failure among them is one, not four.
      job(ctx.card, kind: "merge", status: "failed", error: "checks red")
      assert detect(MergeFailing, ctx.board) == []
    end

    test "two real failures still count with an already-merged one latest", ctx do
      job(ctx.card, kind: "merge", status: "failed", error: "conflict in mix.lock")
      real = job(ctx.card, kind: "merge", status: "failed", error: "checks red")
      job(ctx.card, kind: "merge", status: "failed", output: "merge: #9 is MERGED, not open")

      assert [f] = detect(MergeFailing, ctx.board)
      assert f.state == real.id
      assert f.summary =~ "has failed 2 times, most recently job ##{real.id}"
      refute f.summary =~ "MERGED"
    end

    test "a card still merging that no runner could merge is flagged, not as looping", ctx do
      set_card(ctx.card, verify_state: "merging")
      said = "merge: the pull request is in acme/app, but this runner's repository is x"
      job(ctx.card, kind: "merge", status: "failed", output: said, error: said)
      last = job(ctx.card, kind: "merge", status: "failed", output: said, error: said)

      assert [f] = detect(MergeFailing, ctx.board)
      assert f.state == last.id
      assert f.summary =~ "it is still merging, not sent back as rejected"
      refute f.summary =~ "looping"
    end

    test "near misses: one failure, and a later merge that succeeded", ctx do
      job(ctx.card, kind: "merge", status: "failed", error: "x")
      assert detect(MergeFailing, ctx.board) == []

      job(ctx.card, kind: "merge", status: "failed", error: "y")
      job(ctx.card, kind: "merge", status: "done")
      assert detect(MergeFailing, ctx.board) == []
      assert detect(MergeFailing, ctx.board, %{"failures" => 3}) == []
    end
  end

  describe "verify_slow" do
    defp verifying(ctx, minutes, attrs \\ []) do
      job(
        ctx.card,
        [
          status: "running",
          claimed_at: ago(minutes),
          started_at: ago(minutes),
          lease_expires_at: DateTime.add(now(), 600),
          runner_name: "checker"
        ] ++ attrs
      )
    end

    test "a verify job claimed 70 minutes with no step is found, named for the verdict", ctx do
      job = verifying(ctx, 70)
      assert [f] = detect(VerifySlow, ctx.board)
      assert f.summary =~ "Verify job ##{job.id} (verify, checker)"
      assert f.summary =~ "##{ctx.card.id} waits for its verdict."

      # hung_job leaves it to verify_slow.
      assert detect(HungJob, ctx.board) == []
    end

    test "near misses: a recent step, and 50 minutes", ctx do
      verifying(ctx, 70, step: "tests running", step_at: ago(3))
      assert detect(VerifySlow, ctx.board) == []

      Repo.delete_all(from(j in Job, where: j.card_id == ^ctx.card.id))
      verifying(ctx, 50)
      assert detect(VerifySlow, ctx.board) == []
    end
  end

  test "requeue_verify refuses a card that isn't pending", ctx do
    assert {:error, "the card isn't pending verification"} =
             Slipdock.Verified.requeue_verify(Repo.get!(Card, ctx.card.id))
  end

  test "all four are found by the monitor" do
    keys = Enum.map(Health.detectors(), & &1.key())
    assert Enum.all?(~w(verify_missing merge_missing merge_failing verify_slow), &(&1 in keys))
  end
end
