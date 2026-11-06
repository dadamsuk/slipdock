defmodule Slipdock.CardChatTest do
  @moduledoc """
  The card chat's tools over a card's work record (#1875,
  `Slipdock.AI.CardRecord`) and the loop that runs them
  (`Slipdock.AI.Assistant.chat/4` with an open card): each tool on the card
  and on a subcard, a card outside the tree, a card the asker can't see,
  the step history jobs now keep, and the prompt.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners}
  alias Slipdock.AI.{Assistant, CardRecord, Context}
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Product", "code" => "prod"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns

    epic = card_fixture(todo, %{"title" => "Card chat epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    child = card_fixture(hd(sub.columns), %{"title" => "Tools over the record"})
    other = card_fixture(todo, %{"title" => "Somebody else's card"})

    %{
      owner: owner,
      board: board,
      todo: todo,
      doing: doing,
      epic: Repo.get!(Card, epic.id),
      child: child,
      other: other
    }
  end

  defp call(ctx, name, args \\ %{}), do: CardRecord.call(ctx.owner, ctx.epic, name, args)

  describe "which card a tool reads" do
    test "the open card by default, a subcard by id", ctx do
      assert call(ctx, "read_card") =~ "Card chat epic"
      assert call(ctx, "read_card") =~ "Tools over the record"

      text = call(ctx, "read_card", %{"card_id" => ctx.child.id})
      assert text =~ "Card ##{ctx.child.id}: “Tools over the record”"
      assert text =~ "has no subcards"
    end

    test "a card outside the open card's tree is refused, whoever may read it", ctx do
      for name <- CardRecord.names() -- ["read_job"] do
        text = call(ctx, name, %{"card_id" => ctx.other.id})
        assert text =~ "isn't on this card or beneath it", name
        refute text =~ "Somebody else's card", name
      end
    end

    test "a card the asker can't see is refused by every tool", ctx do
      stranger = user_fixture("stranger@example.com")
      {:ok, _} = Boards.add_comment(ctx.epic, "a secret note")

      for name <- CardRecord.names() -- ["read_job"] do
        text = CardRecord.call(stranger, ctx.epic, name, %{})
        assert text == "There is no card ##{ctx.epic.id} you can see.", name

        text = CardRecord.call(stranger, ctx.epic, name, %{"card_id" => ctx.child.id})
        assert text == "There is no card ##{ctx.child.id} you can see.", name
      end

      job = working_job_fixture(ctx.child)
      text = CardRecord.call(stranger, ctx.epic, "read_job", %{"job_id" => job.id})
      assert text == "There is no card ##{ctx.child.id} you can see."
    end

    test "nonsense ids, missing cards and unknown tools say so", ctx do
      assert call(ctx, "read_card", %{"card_id" => "abc"}) =~ "card_id must be a card's number"
      assert call(ctx, "read_card", %{"card_id" => 999_999_999}) =~ "There is no card #999999999"
      assert call(ctx, "read_card", %{"card_id" => "##{ctx.child.id}"}) =~ "Tools over the record"
      assert call(ctx, "read_job", %{}) =~ "needs a numeric job_id"
      assert call(ctx, "read_job", %{"job_id" => 999_999_999}) =~ "There is no job #999999999"
      assert call(ctx, "drop_tables") == "There is no tool called drop_tables."
    end
  end

  describe "the tools" do
    test "card_comments pages through every comment, oldest first, with ids and authors",
         ctx do
      for i <- 1..27 do
        {:ok, _} = Boards.add_comment(ctx.child, "note #{i}", by: ctx.owner)
      end

      first = call(ctx, "card_comments", %{"card_id" => ctx.child.id})
      assert first =~ "1–25 of 27, oldest first (page 1 of 2)"
      assert first =~ "note 1\n"
      refute first =~ "note 26"
      assert first =~ "More: card_comments with page 2"
      [c1 | _] = Repo.all(from(c in Comment, where: c.card_id == ^ctx.child.id, order_by: c.id))
      assert first =~ "[comment ##{c1.id}]"
      assert first =~ Slipdock.Accounts.User.display_name(ctx.owner)

      second = call(ctx, "card_comments", %{"card_id" => ctx.child.id, "page" => 2})
      assert second =~ "26–27 of 27"
      assert second =~ "note 27"
      refute second =~ "More:"

      # A page past the end is the last page.
      assert call(ctx, "card_comments", %{"card_id" => ctx.child.id, "page" => 9}) =~ "26–27"
      assert call(ctx, "card_comments", %{"card_id" => ctx.other.id}) =~ "isn't on this card"
      assert call(ctx, "card_comments") =~ "has no comments"
    end

    test "card_handoffs lists every handoff, newest first", ctx do
      assert call(ctx, "card_handoffs") =~ "has never had a handoff"
      {:ok, _} = Boards.leave_handoff(ctx.epic, ctx.owner, %{next_step: "First", via: "ui"})

      {:ok, _} =
        Boards.leave_handoff(ctx.epic, ctx.owner, %{
          next_step: "Second",
          body: "- CI red",
          via: "cli"
        })

      text = call(ctx, "card_handoffs")
      assert text =~ "(2)"
      assert text =~ ~r/Next: Second.*Next: First/s
      assert text =~ "- CI red"
      assert text =~ "via cli"
    end

    test "card_links gives links and dependencies", ctx do
      {:ok, _} = Boards.add_dependency(ctx.child, ctx.other)
      {:ok, _} = Boards.add_link(ctx.child, ctx.epic, "relates")

      text = call(ctx, "card_links", %{"card_id" => ctx.child.id})
      assert text =~ "Blocked by: ##{ctx.other.id} “Somebody else's card”"
      assert text =~ "Blocks: none"
      assert text =~ "##{ctx.epic.id} “Card chat epic”"
    end

    test "card_subcards gives each subcard's state and latest job", ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.child.id),
        set: [verify_state: "pending", verify_rejections: 2, flags: ["review"]]
      )

      job = working_job_fixture(ctx.child, %{kind: "verify", status: "queued"})

      text = call(ctx, "card_subcards")
      assert text =~ "0 of 1 done"
      assert text =~ "verification: pending"
      assert text =~ "rejected 2×"
      assert text =~ "flags: review"
      assert text =~ "latest job ##{job.id} (verify, queued)"
      assert call(ctx, "card_subcards", %{"card_id" => ctx.child.id}) =~ "has no subcards"
    end

    test "card_jobs gives each job's times, every step it reported, its outcome", ctx do
      assert call(ctx, "card_jobs") =~ "No runner job has been sent"

      t0 = ~U[2026-11-01 10:00:00Z]

      job =
        working_job_fixture(ctx.child, %{
          kind: "claude",
          pool: "default",
          runner_name: "dev-box",
          status: "done",
          exit_code: 0,
          output: "Built and pushed abc123",
          inserted_at: t0,
          claimed_at: DateTime.add(t0, 51 * 60),
          started_at: DateTime.add(t0, 52 * 60),
          finished_at: DateTime.add(t0, 78 * 60),
          steps: [
            %{"text" => "Plan made", "at" => "2026-11-01T10:53:00Z"},
            %{"text" => "CI running", "at" => "2026-11-01T11:04:00Z"}
          ]
        })

      text = call(ctx, "card_jobs", %{"card_id" => ctx.child.id})
      assert text =~ "Job ##{job.id} · claude · pool default · runner dev-box · done (exit 0)"
      assert text =~ "Queued 2026-11-01 10:00:00 UTC, claimed 2026-11-01 10:51:00 UTC (+51m)"
      assert text =~ "finished 2026-11-01 11:18:00 UTC (+26m)"
      assert text =~ "Steps it reported (2):"
      assert text =~ "2026-11-01 10:53:00 UTC (+1m 0s) Plan made"
      assert text =~ "2026-11-01 11:04:00 UTC (+11m) CI running"
      assert text =~ "Summary: Built and pushed abc123"
      refute text =~ "Prompt:"
    end

    test "a job from before step history says only its latest step was kept", ctx do
      working_job_fixture(ctx.epic, %{step: "Waiting for CI", step_at: ~U[2026-11-01 10:00:00Z]})

      assert call(ctx, "card_jobs") =~
               "Latest step it reported: 2026-11-01 10:00:00 UTC Waiting for CI"

      working_job_fixture(ctx.child)
      assert call(ctx, "card_jobs", %{"card_id" => ctx.child.id}) =~ "Steps: none reported."
    end

    test "read_job gives the prompt only when asked, for a job in the tree only", ctx do
      job = working_job_fixture(ctx.child, %{prompt: "Work card 42 like this"})

      refute call(ctx, "read_job", %{"job_id" => job.id}) =~ "Work card 42"
      assert call(ctx, "read_job", %{"job_id" => job.id, "prompt" => true}) =~ "Work card 42"

      outside = working_job_fixture(ctx.other)
      text = call(ctx, "read_job", %{"job_id" => outside.id})
      assert text =~ "Job ##{outside.id} isn't on this card or beneath it"
    end

    test "card_timeline gives the lists, the waits with their answers and the activity", ctx do
      :ok = Boards.move_card(ctx.epic.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))

      {:ok, wait} =
        Boards.open_wait(ctx.epic, Actor.web(ctx.owner), %{"needs" => "Which pool?"})

      {:ok, _} = Boards.answer_wait(wait, Actor.web(ctx.owner), %{"answer" => "default"})

      text = call(ctx, "card_timeline")
      assert text =~ "Lists it sat in:"
      assert text =~ "- To Do (todo):"
      assert text =~ "- In Progress (doing):"
      assert text =~ "still going"
      assert text =~ "wait ##{wait.id}"
      assert text =~ "Asked: Which pool?"
      assert text =~ "Answer: default"
      assert text =~ "Activity log"

      child = call(ctx, "card_timeline", %{"card_id" => ctx.child.id})
      assert child =~ "Waits on a person:\n- none"
      assert child =~ "Runner jobs:\n- none"
    end

    test "card_verification gives the bar, evidence, every rejection, audits, merge, deploys",
         ctx do
      Repo.update_all(from(c in Card, where: c.id == ^ctx.child.id),
        set: [
          bar: "1. Tools exist",
          bar_locked_at: ~U[2026-11-01 10:00:00Z],
          verify_state: "accepted",
          verify_rejections: 1,
          evidence_commit: "abc1234",
          evidence_pr: "https://github.com/example/repo/pull/7",
          merge_sha: "def5678"
        ]
      )

      {:ok, _} =
        Boards.add_comment(ctx.child, "**Rejected** by verifier.\n\nbar 1: credo fails")

      {:ok, _} = Boards.add_comment(ctx.child, "**Accepted** by verifier.\n\nall good")

      {:ok, _} =
        Boards.add_comment(ctx.child, "**Audit: agrees** with the acceptance, by auditor.")

      {:ok, _} = Boards.add_comment(ctx.child, "an ordinary remark")

      merge =
        working_job_fixture(ctx.child, %{
          kind: Slipdock.Verified.merge_kind(),
          status: "done",
          merged_sha: "def5678"
        })

      text = call(ctx, "card_verification", %{"card_id" => ctx.child.id})
      assert text =~ "Bar: (locked 2026-11-01 10:00:00 UTC)\n1. Tools exist"
      assert text =~ "Commit: `abc1234`"
      assert text =~ "Pull request: https://github.com/example/repo/pull/7"
      assert text =~ "Verdict: accepted"
      assert text =~ "Rejections: 1"
      assert text =~ "bar 1: credo fails"
      assert text =~ "**Accepted** by verifier."
      assert text =~ "**Audit: agrees**"
      refute text =~ "an ordinary remark"
      assert text =~ "Merge jobs: ##{merge.id} done"
      assert text =~ "Merged as: def5678"
      assert text =~ "doesn't record deploys"
    end

    test "card_verification on a card never submitted, and its deploys when they're recorded",
         ctx do
      ctx.board |> Ecto.Changeset.change(delivery_metrics: true) |> Repo.update!()

      text = call(ctx, "card_verification")
      assert text =~ "Bar: none written"
      assert text =~ "Evidence: none on the card now"
      assert text =~ "Verdict: never submitted"
      assert text =~ "no recorded deploy names this card"

      now = DateTime.utc_now()

      Repo.insert!(%Deployment{
        board_id: ctx.board.id,
        environment: "production",
        sha: "0123456789abcdef",
        status: "succeeded",
        started_at: now,
        finished_at: now,
        card_ids: [ctx.epic.id]
      })

      assert call(ctx, "card_verification") =~ "Shipped to production · 0123456"
    end
  end

  describe "job steps" do
    setup ctx do
      {:ok, runner, _token} =
        Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "default"})

      job =
        working_job_fixture(ctx.child, %{
          runner_id: runner.id,
          pool: "default",
          status: "claimed",
          lease_expires_at:
            DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.truncate(:second)
        })

      %{runner: runner, job: job}
    end

    test "every step reported is kept with its time, oldest first", ctx do
      assert {:ok, :ok} = Runners.heartbeat(ctx.runner, ctx.job.id, nil, step: "Plan made")
      assert {:ok, :ok} = Runners.heartbeat(ctx.runner, ctx.job.id, nil, step: "  ")
      assert {:ok, :ok} = Runners.heartbeat(ctx.runner, ctx.job.id, nil)
      assert {:ok, :ok} = Runners.heartbeat(ctx.runner, ctx.job.id, nil, step: "CI running")

      job = Repo.get!(Job, ctx.job.id)
      assert Enum.map(job.steps, & &1["text"]) == ["Plan made", "CI running"]
      assert Enum.all?(job.steps, &match?({:ok, _, _}, DateTime.from_iso8601(&1["at"])))
      assert job.step == "CI running"
    end

    test "only the newest 200 are kept", ctx do
      old = for i <- 1..200, do: %{"text" => "step #{i}", "at" => "2026-11-01T10:00:00Z"}
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id), set: [steps: old])

      assert {:ok, :ok} = Runners.heartbeat(ctx.runner, ctx.job.id, nil, step: "the newest")

      steps = Repo.get!(Job, ctx.job.id).steps
      assert length(steps) == 200
      assert hd(steps)["text"] == "step 2"
      assert List.last(steps)["text"] == "the newest"
    end
  end

  describe "the chat with an open card" do
    defp context(ctx), do: Context.build(%{kind: :card, board: ctx.board, card: ctx.epic})

    test "runs the tools as the asker over several rounds, then answers", ctx do
      job = working_job_fixture(ctx.child, %{status: "failed", error: "credo failed"})

      Slipdock.AIStub.reply_sequence([
        {:tool_calls, [{"card_subcards", %{}}, {"card_jobs", %{"card_id" => ctx.child.id}}]},
        {:tool_calls, [{"read_job", %{"job_id" => job.id}}]},
        "Job ##{job.id} failed: credo."
      ])

      assert {:ok, "Job #" <> _} =
               Assistant.chat(context(ctx), [], "Why did it fail?",
                 user: ctx.owner,
                 card: ctx.epic
               )

      assert_receive {:ai_request, first}
      assert Enum.map(first["tools"], & &1["function"]["name"]) == CardRecord.names()
      [system | _] = first["messages"]
      assert system["content"] =~ "Use them before saying you can't see something"
      assert system["content"] =~ "name what you relied on"
      assert system["content"] =~ "Say plainly when the record doesn't hold the answer"

      assert_receive {:ai_request, second}
      tools = Enum.filter(second["messages"], &(&1["role"] == "tool"))
      assert Enum.map(tools, & &1["name"]) == ["card_subcards", "card_jobs"]
      assert Enum.at(tools, 1)["content"] =~ "Error: credo failed"

      assert_receive {:ai_request, third}
      [_, _, read] = Enum.filter(third["messages"], &(&1["role"] == "tool"))
      assert read["content"] =~ "Job ##{job.id}"
    end

    test "a stranger's tool calls come back refused", ctx do
      stranger = user_fixture("stranger2@example.com")
      {:ok, _} = Boards.add_comment(ctx.epic, "the secret plan")

      Slipdock.AIStub.reply_sequence([{:tool_calls, [{"card_comments", %{}}]}, "Nothing."])

      assert {:ok, "Nothing."} =
               Assistant.chat(context(ctx), [], "Comments?", user: stranger, card: ctx.epic)

      assert_receive {:ai_request, _}
      assert_receive {:ai_request, second}
      tool = Enum.find(second["messages"], &(&1["role"] == "tool"))
      assert tool["content"] =~ "There is no card"
      refute tool["content"] =~ "the secret plan"
    end

    test "out of rounds, it is asked to answer from what it read, with the tools refused",
         ctx do
      Slipdock.AIStub.reply_sequence(
        List.duplicate({:tool_calls, [{"card_jobs", %{}}]}, 8) ++ ["From what I read: no jobs."]
      )

      assert {:ok, "From what I read: no jobs."} =
               Assistant.chat(context(ctx), [], "Loop forever", user: ctx.owner, card: ctx.epic)

      requests =
        for _ <- 1..9 do
          assert_receive {:ai_request, body}
          body
        end

      last = List.last(requests)
      assert last["tool_choice"] == "none"
      assert List.last(last["messages"])["content"] =~ "Answer now"
    end

    test "with no open card, or nobody asking, it is the plain chat it was", ctx do
      Slipdock.AIStub.reply_with("Plain answer.")

      assert {:ok, "Plain answer."} = Assistant.chat(context(ctx), [], "Hi", user: ctx.owner)
      assert_receive {:ai_request, body}
      refute Map.has_key?(body, "tools")
      refute hd(body["messages"])["content"] =~ "card_jobs"

      assert {:ok, "Plain answer."} = Assistant.chat(context(ctx), [], "Hi", card: ctx.epic)
      assert_receive {:ai_request, body}
      refute Map.has_key?(body, "tools")
    end
  end
end
