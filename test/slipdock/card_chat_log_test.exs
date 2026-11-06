defmodule Slipdock.CardChatLogTest do
  @moduledoc """
  The card chat reads a job's log (#1877): `job_log_summary` and `job_log`
  in `Slipdock.AI.CardRecord`, on a running job, a finished one, a kept
  log, an expired one and a job that never sent one, and through a stubbed
  model.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.AI.{Assistant, CardRecord, Context}
  alias Slipdock.Runners.{Job, Transcript, TranscriptRetention}

  @fixture File.read!("test/support/fixtures/transcript_build_job.jsonl")

  setup do
    owner = user_fixture("log-owner@example.com")
    board = board_fixture(%{"name" => "Logs", "code" => "logs"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Show the id"})
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(runner)
    {:ok, 27} = Transcript.append(runner, job.id, 0, @fixture)

    %{owner: owner, board: board, card: card, runner: runner, job: job}
  end

  defp call(ctx, name, args),
    do: CardRecord.call(ctx.owner, ctx.card, name, Map.put_new(args, "job_id", ctx.job.id))

  defp finish(ctx) do
    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})
    Repo.get!(Job, ctx.job.id)
  end

  describe "job_log_summary" do
    test "on a running job: the summary so far, and that more is coming", ctx do
      text = call(ctx, "job_log_summary", %{})

      assert text =~
               "Log of job ##{ctx.job.id} (claude on ##{ctx.card.id}): 27 lines, " <>
                 "still coming in: the job is "

      assert text =~ "Spans 2026-11-05 10:00:00 UTC → 2026-11-05 10:10:50 UTC, 10m."
      assert text =~ "- model (thinking and writing): 1m 23s (13%)"
      assert text =~ "- tools: 9m 27s (87%)"
      assert text =~ "  - tests: 3m 0s over 2 calls"
      assert text =~ "  - ci: 5m 0s over 1 call"
      refute text =~ "  - subagents"

      assert text =~
               "- line 19 · 2026-11-05 10:05:21 UTC · Bash (ci): gh pr checks card-12 --watch --fail-fast · 5m 0s"

      assert text =~ "Failed calls (2):"
      assert text =~ "- line 10 · 2026-11-05 10:00:45 UTC · Bash (tests)"
      assert text =~ "  said: Exit code 2"
      assert text =~ "What the agent said (4 messages):"

      assert text =~
               "- line 12 · 2026-11-05 10:02:55 UTC: The test fails: the id is missing. Fixing."

      assert text =~ "job_log with from and to reads any stretch of it in full."
    end

    test "on a finished job: when its log expires", ctx do
      job = finish(ctx)
      expires = TranscriptRetention.expires_at(job)

      assert call(ctx, "job_log_summary", %{}) =~
               "27 lines, expiring #{CardRecord.at(expires)}."
    end

    test "on a kept log: the page it was kept as", ctx do
      job = finish(ctx)
      {:ok, page, _job} = TranscriptRetention.keep(job, ctx.owner)

      text = call(ctx, "job_log_summary", %{})
      assert text =~ "27 lines, kept as page #{page.code}."
      assert text =~ "- model (thinking and writing): 1m 23s"
    end

    test "a kept log whose lines are gone points at its page", ctx do
      job = finish(ctx)
      {:ok, page, _job} = TranscriptRetention.keep(job, ctx.owner)
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [transcript_lines: 0])

      text = call(ctx, "job_log_summary", %{})
      assert text =~ "isn't on the server any more, but it was kept as page #{page.code}"
    end

    test "an expired log says it expired, and when", ctx do
      finish(ctx)
      later = DateTime.add(DateTime.utc_now(), 30, :day) |> DateTime.truncate(:second)
      assert TranscriptRetention.sweep(later) >= 1

      for name <- ["job_log_summary", "job_log"] do
        text = call(ctx, name, %{})

        assert text =~
                 "Job ##{ctx.job.id}'s log has expired: it was deleted #{CardRecord.at(later)}"

        assert text =~ "read_job"
      end
    end

    test "a job that sent no log says so", ctx do
      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "again"})
      quiet = Repo.one(from(j in Job, where: j.card_id == ^ctx.card.id and j.status == "queued"))

      assert call(ctx, "job_log_summary", %{"job_id" => quiet.id}) ==
               "Job ##{quiet.id} has no log: its runner sent none yet."

      Repo.update_all(from(j in Job, where: j.id == ^quiet.id), set: [status: "done"])

      assert call(ctx, "job_log_summary", %{"job_id" => quiet.id}) =~
               "its runner sent none (runners send one since #1870)."
    end
  end

  describe "job_log" do
    test "a stretch in full: inputs and results, by line", ctx do
      text = call(ctx, "job_log", %{"from" => 10, "to" => 11})

      assert text =~ "Job ##{ctx.job.id}'s log, lines 10–11 of 27 (2 entries;"
      assert text =~ "[line 10] 10:00:45  ▶ Bash: cd /repo && mix test test/app/card_test.exs"
      assert text =~ "[line 11] 10:02:45     ✗ Exit code 2"
      assert text =~ "Assertion with =~ failed"
      assert text =~ "More: job_log from 12."
    end

    test "from the start by default, at most 120 lines, the end without a More", ctx do
      text = call(ctx, "job_log", %{})
      assert text =~ "lines 0–119 of 27"
      assert text =~ "[line 0]"
      assert text =~ "[line 26]"
      refute text =~ "More:"

      assert call(ctx, "job_log", %{"from" => 5, "to" => 900}) =~ "lines 5–124"
      assert call(ctx, "job_log", %{"from" => 25, "to" => 3}) =~ "lines 25–25"
      assert call(ctx, "job_log", %{"from" => 21, "to" => 21}) =~ "… a line of 40000 bytes"
    end

    test "a bad line number, and a job that isn't there", ctx do
      assert call(ctx, "job_log", %{"from" => "abc"}) == "from must be a line number."
      assert call(ctx, "job_log", %{"from" => 1, "to" => "x"}) == "to must be a line number."
      assert call(ctx, "job_log", %{"job_id" => 999_999_999}) =~ "There is no job #999999999"
      assert call(ctx, "job_log_summary", %{"job_id" => "x"}) =~ "needs a numeric job_id"
    end

    test "a job on a card outside the open card's tree is refused", ctx do
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Another"})
      text = CardRecord.call(ctx.owner, other, "job_log", %{"job_id" => ctx.job.id})
      assert text =~ "isn't on this card or beneath it"
      refute text =~ "mix test"
    end
  end

  test "the model reads the summary, then a stretch, as the asker", ctx do
    board = Repo.preload(ctx.board, [:columns, :fields, :tags])
    context = Context.build(%{kind: :card, board: board, card: ctx.card})

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"job_log_summary", %{"job_id" => ctx.job.id}}]},
      {:tool_calls, [{"job_log", %{"job_id" => ctx.job.id, "from" => 10, "to" => 11}}]},
      "CI took 5m 0s (line 19); the first test run failed (lines 10–11)."
    ])

    assert {:ok, "CI took 5m 0s" <> _} =
             Assistant.chat(context, [], "Where did the build's time go?",
               user: ctx.owner,
               card: ctx.card
             )

    assert_receive {:ai_request, first}
    names = Enum.map(first["tools"], & &1["function"]["name"])
    assert "job_log_summary" in names and "job_log" in names
    assert hd(first["messages"])["content"] =~ "read `job_log_summary` first"

    assert_receive {:ai_request, second}
    [summary] = Enum.filter(second["messages"], &(&1["role"] == "tool"))
    assert summary["content"] =~ "  - ci: 5m 0s over 1 call"

    assert_receive {:ai_request, third}
    [_, stretch] = Enum.filter(third["messages"], &(&1["role"] == "tool"))
    assert stretch["content"] =~ "[line 11]"
  end
end
