defmodule Slipdock.Runners.TranscriptRetentionTest do
  # Job logs evaporate unless kept (#1872): each top board's two times, the
  # sweep that deletes logs past them, failures that come after a job ends,
  # and Keep this log.
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners, Verified, Wiki}
  alias Slipdock.Runners.{Job, Transcript, TranscriptChunk, TranscriptRetention}

  @said ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the parser."},{"type":"tool_use","name":"Bash","input":{"command":"mix test"}}]}}\n) <>
          ~s({"type":"assistant","message":{"content":[{"type":"text","text":"All green."}]}}\n)

  setup do
    owner = user_fixture("retention#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Logs", "code" => unique_code()}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Fix the parser"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    %{owner: owner, board: board, card: card, runner: runner}
  end

  # A job on `card` that sent a log and ended `status`, `hours` ago.
  defp ended(ctx, status \\ "done", hours \\ 0, card \\ nil) do
    {:ok, _} = Runners.queue(card || ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(ctx.runner)
    {:ok, 2} = Transcript.append(ctx.runner, job.id, 0, @said)
    exit = if status == "done", do: "0", else: "1"
    {:ok, _} = Runners.finish(ctx.runner, job.id, %{exit: exit, status: status})
    age(job, hours)
  end

  defp age(job, hours) do
    at = DateTime.add(DateTime.utc_now(:second), -hours * 3600, :second)
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [finished_at: at])
    Repo.get!(Job, job.id)
  end

  defp kept?(job), do: Repo.get!(Job, job.id).transcript_lines > 0

  defp chunks(job),
    do: Repo.aggregate(from(c in TranscriptChunk, where: c.job_id == ^job.id), :count)

  describe "the board's two times" do
    test "default to a day, and a week for a failure", ctx do
      assert ctx.board.job_log_hours == 24
      assert ctx.board.failure_log_hours == 168

      fresh = ended(ctx, "done", 23)
      stale = ended(ctx, "done", 25)
      failed = ended(ctx, "failed", 24 * 6)
      old_failure = ended(ctx, "failed", 24 * 8)
      timeout = ended(ctx, "timeout", 30)

      assert TranscriptRetention.sweep() == 2
      assert kept?(fresh)
      refute kept?(stale)
      assert kept?(failed)
      refute kept?(old_failure)
      # A timeout is a failure: 30 hours is inside its week.
      assert kept?(timeout)
    end

    test "take the board's own values", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"job_log_hours" => 2, "failure_log_hours" => 5})
      inside = ended(ctx, "done", 1)
      past = ended(ctx, "done", 3)
      failed_inside = ended(ctx, "cancelled", 4)
      failed_past = ended(ctx, "cancelled", 6)

      assert TranscriptRetention.sweep() == 2
      assert kept?(inside) and kept?(failed_inside)
      refute kept?(past) or kept?(failed_past)
    end

    test "a sub-board's jobs follow the top board", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"job_log_hours" => 1})
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      sub_card = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Part"})
      job = ended(ctx, "done", 2, sub_card)
      assert job.board_id == sub.id

      assert TranscriptRetention.expires_at(job) ==
               DateTime.add(job.finished_at, 3600, :second)

      assert TranscriptRetention.sweep() == 1
      refute kept?(job)
    end

    test "are refused outside 1 hour to a year", ctx do
      for bad <- [0, -1, 8761] do
        assert {:error, cs} = Boards.update_board(ctx.board, %{"job_log_hours" => bad})
        assert %{job_log_hours: [_]} = errors_on(cs)
        assert {:error, cs} = Boards.update_board(ctx.board, %{"failure_log_hours" => bad})
        assert %{failure_log_hours: [_]} = errors_on(cs)
      end
    end
  end

  describe "the sweep" do
    test "deletes the log and keeps the job", ctx do
      job = ended(ctx, "done", 30)
      assert chunks(job) > 0
      assert TranscriptRetention.sweep() == 1

      job = Repo.get!(Job, job.id)
      assert chunks(job) == 0
      assert job.status == "done"
      assert job.transcript_lines == 0 and job.transcript_bytes == 0
      assert job.transcript_deleted_at
      assert Transcript.read(job) == ""
      assert TranscriptRetention.expires_at(job) == nil
      # Nothing left to go.
      assert TranscriptRetention.sweep() == 0
    end

    test "leaves open jobs, jobs with no log and kept logs", ctx do
      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
      running = Runners.claim(ctx.runner)
      {:ok, 2} = Transcript.append(ctx.runner, running.id, 0, @said)

      Repo.update_all(from(j in Job, where: j.id == ^running.id),
        set: [claimed_at: DateTime.add(DateTime.utc_now(:second), -90 * 86_400)]
      )

      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
      silent = Runners.claim(ctx.runner)
      {:ok, _} = Runners.finish(ctx.runner, silent.id, %{exit: "0"})
      age(silent, 100)

      {:ok, _} = Runners.finish(ctx.runner, running.id, %{exit: "0"})
      kept = age(running, 100)
      {:ok, _page, _} = TranscriptRetention.keep(kept, ctx.owner)

      assert TranscriptRetention.sweep() == 0
      assert kept?(kept)
      assert TranscriptRetention.expires_at(Repo.get!(Job, kept.id)) == nil
      assert TranscriptRetention.expires_at(Repo.get!(Job, silent.id)) == nil
    end

    test "says when a log goes: from the end, or a failure's time", ctx do
      done = ended(ctx, "done")
      failed = ended(ctx, "failed")
      assert TranscriptRetention.expires_at(done) == DateTime.add(done.finished_at, 24 * 3600)

      assert TranscriptRetention.expires_at(failed) ==
               DateTime.add(failed.finished_at, 168 * 3600)

      refute TranscriptRetention.failure?(done)
      assert TranscriptRetention.failure?(failed)
    end
  end

  describe "a failure after the job ended" do
    test "moves a done job to the failure time, from then", ctx do
      job = ended(ctx, "done", 30)
      now = DateTime.utc_now(:second)
      assert TranscriptRetention.mark_failed([job.id], now) == 1
      job = Repo.get!(Job, job.id)

      assert TranscriptRetention.failure?(job)
      assert TranscriptRetention.expires_at(job) == DateTime.add(now, 168 * 3600)
      assert TranscriptRetention.sweep() == 0
      assert kept?(job)
    end

    test "rejecting the card marks its build job and the verify job", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
      [_backlog, _todo, doing | _] = board.columns
      card = card_fixture(doing, %{"title" => "Checked"})
      build = ended(ctx, "done", 30, card)
      agent = %{Actor.unknown() | kind: "agent", via: "cli", user_id: ctx.owner.id, agent: "b"}

      {:ok, card} =
        Boards.Cards.update_card(Repo.get!(Boards.Card, card.id), %{"completed" => true},
          actor: agent
        )

      assert card.verify_state == "pending"
      {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "verify", prompt: "check"})
      verify = Runners.claim(ctx.runner)
      {:ok, 2} = Transcript.append(ctx.runner, verify.id, 0, @said)
      {:ok, _} = Runners.finish(ctx.runner, verify.id, %{exit: "0"})
      verify = age(verify, 30)
      other = ended(ctx, "done", 30)

      checker = %{agent | agent: "checker"}

      {:ok, _} =
        Verified.decide(card, "reject", %{"reason" => "the ask: no tests"}, checker, ctx.owner)

      assert Repo.get!(Job, build.id).transcript_failed_at
      assert Repo.get!(Job, verify.id).transcript_failed_at
      refute Repo.get!(Job, other.id).transcript_failed_at
      # Both stay a week from the rejection; the other card's day is up.
      assert TranscriptRetention.sweep() == 1
      assert kept?(build) and kept?(verify)
      refute kept?(other)
    end

    test "flagged stuck marks only the card's work job", ctx do
      job = ended(ctx, "done", 1)
      assert TranscriptRetention.card_failed(ctx.card, verify: false) == 1
      assert Repo.get!(Job, job.id).transcript_failed_at
      assert TranscriptRetention.card_failed(%{id: nil}) == 0
    end

    test "a kept or deleted log isn't marked", ctx do
      gone = ended(ctx, "done", 30)
      TranscriptRetention.sweep()
      kept = ended(ctx, "done")
      {:ok, _, _} = TranscriptRetention.keep(kept, ctx.owner)
      assert TranscriptRetention.mark_failed([gone.id, kept.id]) == 0
      assert TranscriptRetention.mark_failed([]) == 0
    end
  end

  describe "Keep this log" do
    test "writes a Pass page in the card's folder, links it and stops the expiry", ctx do
      job = ended(ctx, "done", 1)
      assert {:ok, page, job} = TranscriptRetention.keep(job, ctx.owner)

      date = Calendar.strftime(job.finished_at, "%Y-%m-%d %H.%M")
      assert page.title == "Pass #{ctx.card.id} (#{date})"
      assert page.summary == "Full output of the pass on ##{ctx.card.id}"

      assert page.body ==
               "Pass on ##{ctx.card.id}, job ##{job.id}, exit 0.\n\nFixed the parser.\n\nAll green.\n"

      assert job.transcript_page_id == page.id
      assert TranscriptRetention.expires_at(job) == nil
      # Pinned to the card, and filed in its folder, where "Write it up" puts a page.
      assert Enum.any?(Wiki.pages_for_card(ctx.card, ctx.owner), &(&1.page_id == page.id))
      {:ok, write_up} = Wiki.create_page_from_card(ctx.card, user: ctx.owner)
      assert page.folder_id && page.folder_id == write_up.folder_id
    end

    test "twice gives one page", ctx do
      job = ended(ctx, "done")
      {:ok, first, _} = TranscriptRetention.keep(job, ctx.owner)
      {:ok, again, _} = TranscriptRetention.keep(Repo.get!(Job, job.id), ctx.owner)
      assert again.id == first.id
      assert Repo.aggregate(from(p in Wiki.Page, where: p.title == ^first.title), :count) == 1
    end

    test "titles the page in the keeper's timezone", ctx do
      job = %Job{card_id: 7, finished_at: ~U[2026-07-01 23:30:00Z]}

      assert TranscriptRetention.title(job, %{timezone: "Pacific/Auckland"}) ==
               "Pass 7 (2026-07-02 11.30)"

      assert TranscriptRetention.title(job, nil) == "Pass 7 (2026-07-01 23.30)"

      assert TranscriptRetention.title(job, %{timezone: "Not/AZone"}) ==
               "Pass 7 (2026-07-01 23.30)"
    end

    test "is refused while the job runs, and with no log left", ctx do
      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
      running = Runners.claim(ctx.runner)
      {:ok, 2} = Transcript.append(ctx.runner, running.id, 0, @said)
      assert TranscriptRetention.keep(running, ctx.owner) == {:error, :running}

      gone = ended(ctx, "done", 30)
      TranscriptRetention.sweep()
      assert TranscriptRetention.keep(gone, ctx.owner) == {:error, :no_log}
      assert TranscriptRetention.refusal(:running) =~ "still running"
      assert TranscriptRetention.refusal(:no_log) =~ "expired"
    end
  end
end
