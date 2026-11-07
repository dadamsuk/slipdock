defmodule Slipdock.CostTest do
  @moduledoc """
  Cost on the card (#1954): what a job's log says it spent, kept on the job
  (`Slipdock.Runners.JobCost`), and put beside lead time by phase
  (`Slipdock.LeadTime`), rolled up for an epic, on the ledger line and in
  the card chat's `card_lead_time`. A log with usage, one without, the
  phase split, the epic rollup, the count kept past the log's deletion,
  and tokens left out rather than 0 when unknown.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, LeadTime, Ledger, Repo, Runners}
  alias Slipdock.AI.CardRecord
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Runners.{Job, JobCost, Transcript, TranscriptChunk, TranscriptRetention}
  alias Slipdock.Runners.TranscriptSummary

  @t0 ~U[2026-11-05 12:00:00Z]

  defp t(min), do: DateTime.add(@t0, round(min * 60), :second)
  defp ts(sec), do: @t0 |> DateTime.add(sec, :second) |> DateTime.to_iso8601()

  # An assistant line at `sec`, with `usage` (and its message id) or none.
  defp said(sec, id, usage, content \\ [%{type: "text", text: "Working."}]) do
    message = %{role: "assistant", content: content}
    message = if id, do: Map.put(message, :id, id), else: message
    message = if usage, do: Map.put(message, :usage, usage), else: message
    Jason.encode!(%{type: "assistant", timestamp: ts(sec), message: message})
  end

  defp result(sec, tool_id) do
    Jason.encode!(%{
      type: "user",
      timestamp: ts(sec),
      message: %{content: [%{type: "tool_result", tool_use_id: tool_id, content: "ok"}]}
    })
  end

  defp usage(input, output, read \\ 0, write \\ 0),
    do: %{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: read,
      cache_creation_input_tokens: write
    }

  # A log 100s long: 10s of model, then a 60s test run, then 30s of model.
  # Message m1 comes on two lines (its text, then its tool call) with the
  # same usage: it counts once. m2 has usage; a line with no id counts too.
  defp with_usage do
    [
      said(0, "m1", usage(100, 5, 1000, 50)),
      said(10, "m1", usage(100, 5, 1000, 50), [
        %{type: "tool_use", id: "t1", name: "Bash", input: %{command: "mix test"}}
      ]),
      result(70, "t1"),
      said(90, "m2", usage(20, 300, 2000, 0)),
      said(100, nil, usage(1, 2))
    ]
    |> Enum.join("\n")
  end

  defp without_usage do
    [
      said(0, "m1", nil),
      said(10, "m1", nil, [
        %{type: "tool_use", id: "t1", name: "Bash", input: %{command: "mix test"}}
      ]),
      result(70, "t1"),
      said(100, "m2", nil)
    ]
    |> Enum.join("\n")
  end

  setup do
    owner = user_fixture("cost#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Cost", "code" => unique_code()}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    card = card_fixture(todo, %{"title" => "Count the cost"})

    %{
      owner: owner,
      board: board,
      backlog: backlog,
      todo: todo,
      doing: doing,
      done: done,
      card: card
    }
  end

  # A job on `card` with `log` stored as its transcript.
  defp job!(card, kind, log, attrs \\ %{}) do
    job =
      working_job_fixture(
        card,
        Map.merge(
          %{
            kind: kind,
            status: "done",
            inserted_at: t(0),
            claimed_at: t(1),
            started_at: t(1),
            finished_at: t(10)
          },
          attrs
        )
      )

    if log, do: log!(job, log), else: job
  end

  defp log!(job, log) do
    lines = log |> String.split("\n") |> length()
    body = log <> "\n"

    Repo.insert!(%TranscriptChunk{
      job_id: job.id,
      first_line: job.transcript_lines,
      lines: lines,
      bytes: byte_size(body),
      body: body
    })

    {_, [job]} =
      Repo.update_all(from(j in Job, where: j.id == ^job.id, select: j),
        inc: [transcript_lines: lines, transcript_bytes: byte_size(body)]
      )

    job
  end

  describe "the summary's count" do
    test "a log with usage: time split as the summary does, tokens once per message" do
      cost = TranscriptSummary.cost(with_usage())
      sum = TranscriptSummary.summarise(with_usage())

      assert cost.lines == 5
      assert {cost.model_seconds, cost.tool_seconds} == {40, 60}
      assert {sum.model_seconds, sum.tool_seconds} == {40, 60}
      # m1 once (not twice), m2, and the line with no id.
      assert cost.tokens == %{input: 121, output: 307, cache_read: 3000, cache_write: 50}
      assert sum.tokens == cost.tokens
    end

    test "a log without usage has no tokens, not zero; its time is still counted" do
      cost = TranscriptSummary.cost(without_usage())
      assert cost.tokens == nil
      assert {cost.model_seconds, cost.tool_seconds} == {40, 60}

      fixture = File.read!("test/support/fixtures/transcript_build_job.jsonl")
      assert TranscriptSummary.summarise(fixture).tokens == nil
    end

    test "usage of all zeros, or of the wrong shape, isn't usage" do
      log =
        Enum.join(
          [
            said(0, "m1", usage(0, 0)),
            said(5, "m2", %{input_tokens: "lots", output_tokens: -3})
          ],
          "\n"
        )

      assert TranscriptSummary.cost(log).tokens == nil
      assert TranscriptSummary.cost("").tokens == nil
      assert TranscriptSummary.cost("not json\n").lines == 0
    end
  end

  describe "a job's cost, kept on the job" do
    test "counted from its log once, and again only when the log grows", %{card: card} do
      job = job!(card, "claude", without_usage())
      assert job.cost_lines == 0

      assert JobCost.of(job) == %{model_seconds: 40, tool_seconds: 60, tokens: nil}
      kept = Repo.get!(Job, job.id)
      assert kept.cost_lines == 4
      assert kept.tokens == nil

      # Nothing new: what was kept is answered, the log isn't read again.
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [model_seconds: 999])
      assert JobCost.of(Repo.get!(Job, job.id)).model_seconds == 999

      # The log grows: counted again, usage and all.
      grown = log!(Repo.get!(Job, job.id), said(130, "m3", usage(10, 20)))
      assert %{model_seconds: 70, tool_seconds: 60, tokens: tokens} = JobCost.of(grown)
      assert tokens == %{input: 10, output: 20, cache_read: 0, cache_write: 0}

      assert Repo.get!(Job, job.id).tokens == %{
               "input" => 10,
               "output" => 20,
               "cache_read" => 0,
               "cache_write" => 0
             }
    end

    test "a job whose runner sent no log has no cost", %{card: card} do
      assert JobCost.of(job!(card, "claude", nil)) == nil
    end

    test "outlives its log: the sweep counts a log before deleting it", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})
      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})
      job = Runners.claim(runner)
      {:ok, 5} = Transcript.append(runner, job.id, 0, with_usage() <> "\n")
      {:ok, _} = Runners.finish(runner, job.id, %{exit: "0", status: "done"})
      old = DateTime.add(DateTime.utc_now(:second), -48 * 3600, :second)
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [finished_at: old])

      assert Repo.get!(Job, job.id).cost_lines == 0
      assert TranscriptRetention.sweep() == 1

      gone = Repo.get!(Job, job.id)
      assert gone.transcript_lines == 0 and gone.transcript_deleted_at
      assert %{model_seconds: 40, tool_seconds: 60, tokens: %{input: 121}} = JobCost.of(gone)
    end

    test "sum: nils skipped, tokens only over the jobs that have them" do
      a = %{model_seconds: 10, tool_seconds: 20, tokens: nil}

      b = %{
        model_seconds: 1,
        tool_seconds: 2,
        tokens: %{input: 5, output: 6, cache_read: 7, cache_write: 8}
      }

      assert JobCost.sum([nil, nil]) == nil
      assert JobCost.sum([]) == nil

      assert JobCost.sum([a, nil]) == %{model_seconds: 10, tool_seconds: 20, tokens: nil, jobs: 1}

      assert JobCost.sum([a, b]) == %{
               model_seconds: 11,
               tool_seconds: 22,
               tokens: %{input: 5, output: 6, cache_read: 7, cache_write: 8},
               jobs: 2
             }
    end

    test "text and json leave unknown tokens out rather than saying 0" do
      known = %{
        model_seconds: 750,
        tool_seconds: 4000,
        tokens: %{input: 1_000_000, output: 200_000, cache_read: 0, cache_write: 0},
        jobs: 2
      }

      unknown = %{known | tokens: nil}

      assert JobCost.text(known) == "model 12m · tools 1h 6m · 1.2M tokens"
      assert JobCost.text(unknown) == "model 12m · tools 1h 6m"
      assert JobCost.text(nil) == nil
      assert JobCost.tokens_text(950) == "950"
      assert JobCost.tokens_text(12_340) == "12.3k"

      assert JobCost.json(unknown) == %{model_seconds: 750, tool_seconds: 4000, jobs: 2}
      assert JobCost.json(known).tokens.total == 1_200_000
      assert JobCost.json(nil) == nil
    end
  end

  describe "beside lead time" do
    test "each job's cost goes to the phase of its run", %{card: card} do
      job!(card, "claude", with_usage(), %{claimed_at: t(1), finished_at: t(10)})

      job!(card, "verify", without_usage(), %{
        inserted_at: t(11),
        claimed_at: t(12),
        finished_at: t(14)
      })

      Repo.insert!(%Comment{
        card_id: card.id,
        body: "**Rejected** by the verifier",
        inserted_at: t(15),
        updated_at: t(15)
      })

      job!(card, "claude", without_usage(), %{
        inserted_at: t(16),
        claimed_at: t(17),
        finished_at: t(20)
      })

      job!(card, Slipdock.Verified.merge_kind(), without_usage(), %{
        inserted_at: t(21),
        claimed_at: t(21),
        finished_at: t(22)
      })

      # A job with no log adds nothing, to any phase.
      job!(card, "claude", nil, %{inserted_at: t(23), claimed_at: t(23), finished_at: t(24)})

      %{cost: cost} = LeadTime.for_card(Repo.get!(Card, card.id), now: t(30))

      assert Map.keys(cost.phases) |> Enum.sort() == [:build, :merge, :rework, :verify]

      assert cost.phases.build.tokens == %{
               input: 121,
               output: 307,
               cache_read: 3000,
               cache_write: 50
             }

      assert cost.phases.build.jobs == 1
      assert cost.phases.verify.tokens == nil
      assert cost.phases.rework.model_seconds == 40
      assert cost.phases.merge.tool_seconds == 60

      assert cost.total.jobs == 4
      assert cost.total.model_seconds == 160 and cost.total.tool_seconds == 240
      # Tokens from the one log that had them; the others add none.
      assert cost.total.tokens.output == 307
    end

    test "no job sent a log: the cost is nil, and so is the panel's line on an idle card",
         %{card: card, todo: todo} do
      job!(card, "claude", nil)
      assert LeadTime.for_card(Repo.get!(Card, card.id), now: t(30)).cost == nil

      idle = card_fixture(todo, %{"title" => "Nobody touched it"})
      assert LeadTime.worked_brief(idle) == nil

      assert %{cost: nil, rollup: nil, seconds: _} =
               LeadTime.worked_brief(Repo.get!(Card, card.id))
    end

    test "an epic rolls up its subcards' costs with its own jobs'", ctx do
      epic = card_fixture(ctx.doing, %{"title" => "The epic"})
      {:ok, template} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, template)
      [sub_todo | _] = Boards.get_board!(sub.id).columns
      one = card_fixture(sub_todo, %{"title" => "One"})
      two = card_fixture(sub_todo, %{"title" => "Two"})
      _quiet = card_fixture(sub_todo, %{"title" => "No jobs"})

      job!(epic, "claude", without_usage())
      job!(one, "claude", with_usage())
      job!(two, "verify", with_usage())

      epic = Repo.get!(Card, epic.id)
      %{card: own, subcards: subs, total: total} = LeadTime.for_epic(epic, now: t(30))

      assert own.cost.total.jobs == 1
      assert own.cost.total.tokens == nil
      assert length(subs) == 3
      assert total.cost.total.jobs == 3
      assert total.cost.total.model_seconds == 120
      assert total.cost.total.tokens.input == 242
      assert Map.keys(total.cost.phases) |> Enum.sort() == [:build, :verify]
      assert total.cost.phases.build.jobs == 2

      brief = LeadTime.brief(epic, now: t(30))
      assert brief.rollup.subcards == 3
      assert brief.rollup.cost.total.jobs == 3
      assert brief.cost.total.jobs == 1
    end
  end

  describe "where it is read" do
    test "the ledger line carries the total, or nil", %{board: board, done: done} do
      now = DateTime.utc_now(:second)
      priced = card_fixture(done, %{"title" => "Priced"})
      plain = card_fixture(done, %{"title" => "Plain"})

      for c <- [priced, plain],
          do:
            Repo.update_all(from(x in Card, where: x.id == ^c.id),
              set: [completed: true, completed_at: now]
            )

      job!(priced, "claude", with_usage())

      {:ok, ledger} =
        Ledger.since(board, since: DateTime.add(now, -3600, :second), timezone: "Etc/UTC")

      items = Enum.flat_map(ledger.days, & &1.items)
      line = Enum.find(items, &(&1.card.id == priced.id))
      assert line.lead_time.cost.jobs == 1
      assert line.lead_time.cost.tokens.output == 307
      assert Enum.find(items, &(&1.card.id == plain.id)).lead_time.cost == nil
    end

    test "card_lead_time says what was spent, by phase, and when tokens aren't known",
         %{owner: owner, card: card, todo: todo} do
      job!(card, "claude", with_usage())

      job!(card, "verify", without_usage(), %{
        inserted_at: t(11),
        claimed_at: t(12),
        finished_at: t(14)
      })

      text = CardRecord.call(owner, Repo.get!(Card, card.id), "card_lead_time", %{})

      assert text =~
               "Spent by its jobs (from their logs): model 1m · tools 2m · 3.5k tokens (2 jobs)."

      assert text =~ "- build: model 40s · tools 1m · 3.5k tokens (1 job)"
      assert text =~ "- verify: model 40s · tools 1m (1 job)"

      bare = card_fixture(todo, %{"title" => "No logs"})
      job!(bare, "claude", without_usage())
      text = CardRecord.call(owner, bare, "card_lead_time", %{})
      assert text =~ "No log carried token usage, so tokens aren't known."
      refute text =~ "0 tokens"

      none = card_fixture(todo, %{"title" => "Never sent"})
      text = CardRecord.call(owner, none, "card_lead_time", %{})
      assert text =~ "Spent: not known (no job on it sent a log)."
    end
  end
end
