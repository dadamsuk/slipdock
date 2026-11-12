defmodule Slipdock.LeadTimeTest do
  @moduledoc """
  Where a card's time went (#1876, `Slipdock.LeadTime`): each phase from
  a record built by hand with fixed times, the worked example (#1856's
  shape), a rejection and its rework, a card no job was sent on, gaps the
  record can't explain, an epic and its subcards, and the card chat's
  `card_lead_time` tool, alone and through a stubbed model.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, LeadTime, Repo}
  alias Slipdock.AI.{Assistant, CardRecord, Context}
  alias Slipdock.Boards.{Card, CardMove, Comment, Wait}
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Runners.Job

  @t0 ~U[2026-11-05 12:00:00Z]

  defp t(min), do: DateTime.add(@t0, round(min * 60), :second)
  defp us(%DateTime{} = at), do: %{at | microsecond: {0, 6}}

  setup do
    owner = user_fixture("lead-owner@example.com")
    board = board_fixture(%{"name" => "Lead", "code" => "lead"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    card = card_fixture(backlog, %{"title" => "Show the id"})

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

  ## Building a record ----------------------------------------------------------

  # Replaces the card's movement ledger with `stays`: [{minute, column}],
  # the first its creation, and sets its creation and completion.
  defp record!(card, stays, opts \\ []) do
    Repo.delete_all(from(m in CardMove, where: m.card_id == ^card.id))

    froms = [nil | Enum.map(stays, &elem(&1, 1))]

    for {{{min, col}, prev}, i} <- stays |> Enum.zip(froms) |> Enum.with_index() do
      Repo.insert!(%CardMove{
        card_id: card.id,
        board_id: col.board_id,
        kind: if(i == 0, do: "created", else: "moved"),
        from_column_name: prev && prev.name,
        from_category: prev && prev.category,
        to_column_name: col.name,
        to_category: col.category,
        inserted_at: us(t(min))
      })
    end

    {created, _} = hd(stays)
    done = opts[:completed]

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [
        inserted_at: t(created),
        completed: not is_nil(done),
        completed_at: done && t(done)
      ]
    )

    Repo.get!(Card, card.id)
  end

  defp job!(card, kind, queued, claimed, finished, attrs \\ %{}) do
    working_job_fixture(
      card,
      Map.merge(
        %{
          kind: kind,
          pool: "loop",
          status: "done",
          inserted_at: t(queued),
          claimed_at: claimed && t(claimed),
          started_at: claimed && t(claimed),
          finished_at: finished && t(finished)
        },
        attrs
      )
    )
  end

  defp comment!(card, min, body) do
    Repo.insert!(%Comment{card_id: card.id, body: body, inserted_at: t(min), updated_at: t(min)})
  end

  defp segments(lt), do: Enum.map(lt.segments, &{&1.phase, &1.seconds})

  ## The worked example ---------------------------------------------------------

  describe "a card a runner built" do
    # #1856's shape: 1 min in the backlog, 51 min ready behind another
    # card's job, 11 min build, CI red with the fix reported alongside,
    # CI green, verify, merge, then a deploy 5 min later.
    setup ctx do
      other = card_fixture(ctx.todo, %{"title" => "The epic pass"})
      busy = job!(other, "claude", 0, 0.5, 52)

      card =
        record!(ctx.card, [{0, ctx.backlog}, {1, ctx.todo}, {52.5, ctx.doing}, {80, ctx.done}],
          completed: 80
        )

      job = job!(card, "claude", 51.75, 52, 78.5)
      comment!(card, 63, "**Build started.**\n\n- Run: Test #1")

      failed =
        comment!(card, 73, """
        **Build failed:** Test #1 — job `static checks`, step credo diff.

        - Fixed in `b1d66f3`.

        **Build started.** Test #2
        """)

      comment!(card, 78, "Build passed: Test #2")
      comment!(card, 78.1, "**Done** — submitted. CI: failed once, then passed")
      verify = job!(card, "verify", 78.2, 78.2, 79.4, %{pool: "verify"})
      merge = job!(card, "merge", 79.4, 79.4, 80)
      _audit = job!(card, "verify", 81, 81, 82, %{pool: "verify", audit: true})

      ctx.board |> Ecto.Changeset.change(delivery_metrics: true) |> Repo.update!()

      Repo.insert!(%Deployment{
        board_id: ctx.board.id,
        environment: "production",
        sha: "abc",
        status: "succeeded",
        started_at: us(t(85)),
        finished_at: us(t(85.5)),
        card_ids: [card.id]
      })

      %{card: card, busy: busy, job: job, failed: failed, verify: verify, merge: merge}
    end

    test "every phase, in order, from creation to the first deploy", ctx do
      lt = LeadTime.for_card(ctx.card, now: t(200))

      assert lt.ends == :deployed
      assert lt.from == t(0) and lt.to == t(85.5)
      assert lt.done_at == t(80)
      assert lt.seconds == 85 * 60 + 30
      assert lt.done_seconds == 80 * 60

      assert segments(lt) == [
               {:backlog, 60},
               {:waiting_for_runner, 3045},
               {:waiting_for_runner, 15},
               {:build, 660},
               {:ci, 600},
               {:ci, 300},
               {:build, 12},
               {:verify, 72},
               {:merge, 36},
               {:deploy, 330}
             ]

      assert lt.totals.unexplained == 0
      assert lt.totals.waiting_for_runner == 3060
      assert lt.totals.ci == 900
      assert Enum.sum(Map.values(lt.totals)) == lt.seconds
    end

    test "names the jobs that held the pool, and what each span came from", ctx do
      lt = LeadTime.for_card(ctx.card, now: t(200))
      [_, ready, queued | _] = lt.segments

      assert ready.note == "in the ready list #{ctx.todo.name}"
      assert [%{job_id: id, card_id: other, title: "The epic pass"}] = ready.held_by
      assert id == ctx.busy.id and other != ctx.card.id
      assert queued.refs == ["job ##{ctx.job.id}"]

      [red, green] = Enum.filter(lt.segments, &(&1.phase == :ci))
      assert red.note =~ "red; the failure was reported with its fix already pushed"
      assert red.note =~ "comment ##{ctx.failed.id}"
      assert green.note == "CI, green"
      assert Enum.find(lt.segments, &(&1.phase == :merge)).refs == ["job ##{ctx.merge.id}"]
    end

    test "the audit after acceptance claims nothing", ctx do
      lt = LeadTime.for_card(ctx.card, now: t(200))
      refute Enum.any?(lt.segments, &(&1.from == t(81)))
    end

    test "without delivery metrics it ends at done", ctx do
      Repo.update_all(from(b in Slipdock.Boards.Board, where: b.id == ^ctx.board.id),
        set: [delivery_metrics: false]
      )

      lt = LeadTime.for_card(ctx.card, now: t(200))

      assert lt.ends == :completed
      assert lt.to == t(80)
      assert lt.totals.deploy == 0
    end
  end

  ## Rejection, waits, steps --------------------------------------------------

  describe "other paths through the record" do
    test "work after a rejection is rework, and a queued verify job is a verification wait",
         ctx do
      card = record!(ctx.card, [{0, ctx.doing}, {40, ctx.done}], completed: 40)
      job!(card, "claude", 0, 0, 10)
      job!(card, "verify", 10, 12, 14, %{pool: "verify"})
      comment!(card, 14, "**Rejected** by runner verifier: bar 2 isn't met")
      job!(card, "claude", 14, 15, 30)
      job!(card, "verify", 30, 30, 39, %{pool: "verify"})
      job!(card, "merge", 39, 39, 40)

      lt = LeadTime.for_card(card, now: t(60))

      assert segments(lt) == [
               {:build, 600},
               {:verification_wait, 120},
               {:verify, 120},
               {:waiting_for_runner, 60},
               {:rework, 900},
               {:verify, 540},
               {:merge, 60}
             ]

      assert Enum.find(lt.segments, &(&1.phase == :rework)).note == "after a rejection"
    end

    test "a wait on a person outranks the job it parked, and steps mark CI", ctx do
      card = record!(ctx.card, [{0, ctx.doing}])

      job!(card, "claude", 0, 0, 30, %{
        steps: [
          %{"text" => "Plan made", "at" => DateTime.to_iso8601(t(1))},
          %{"text" => "Pushed; CI running", "at" => DateTime.to_iso8601(t(20))},
          %{"text" => "Submitted: PR #9, CI green", "at" => DateTime.to_iso8601(t(25))}
        ]
      })

      wait =
        Repo.insert!(%Wait{
          card_id: card.id,
          needs: "Which colour?",
          on_user_id: ctx.owner.id,
          inserted_at: t(5),
          closed_at: t(15),
          close_reason: "answered"
        })

      lt = LeadTime.for_card(card, now: t(30))

      assert segments(lt) == [
               {:build, 300},
               {:waiting_on_person, 600},
               {:build, 300},
               {:ci, 300},
               {:build, 300}
             ]

      waiting = Enum.find(lt.segments, &(&1.phase == :waiting_on_person))
      assert waiting.refs == ["wait ##{wait.id}"]
      assert waiting.note =~ "waiting on"
      assert lt.ends == :open
    end

    test "a CI run nothing reported the end of lasts until its job ended", ctx do
      card = record!(ctx.card, [{0, ctx.doing}])
      job!(card, "claude", 0, 0, 20)
      comment!(card, 10, "Build started.\n\n- Work complete and pushed")
      # A comment that only talks about the words is no event.
      comment!(card, 12, "**Plan.** watch for the `Build passed` comment")

      lt = LeadTime.for_card(card, now: t(30))

      assert segments(lt) == [{:build, 600}, {:ci, 600}, {:unexplained, 600}]
      assert Enum.find(lt.segments, &(&1.phase == :ci)).note == "CI, no result recorded"
    end

    test "a card no job was sent on: ready, then a person's work", ctx do
      card =
        record!(ctx.card, [{0, ctx.todo}, {10, ctx.doing}, {30, ctx.done}], completed: 30)

      lt = LeadTime.for_card(card, now: t(60))

      assert lt.jobs == 0
      assert segments(lt) == [{:waiting_for_runner, 600}, {:build, 1200}]
      assert [%{held_by: []} | _] = lt.segments
      assert Enum.at(lt.segments, 1).note =~ "no runner job: worked by hand"
    end

    test "an open card with no jobs runs to now", ctx do
      card = record!(ctx.card, [{0, ctx.backlog}])
      lt = LeadTime.for_card(card, now: t(5))

      assert lt.ends == :open
      assert lt.to == t(5)
      assert segments(lt) == [{:backlog, 300}]
      assert lt.done_seconds == nil
    end

    test "time the record holds nothing for is unexplained, not spread", ctx do
      card = record!(ctx.card, [{0, ctx.doing}, {30, ctx.done}], completed: 30)
      job!(card, "claude", 0, 0, 10)
      job!(card, "claude", 20, 20, 30)

      lt = LeadTime.for_card(card, now: t(60))

      assert segments(lt) == [{:build, 600}, {:unexplained, 600}, {:build, 600}]
      assert lt.totals.unexplained == 600
    end

    test "a card with no time at all has no segments", ctx do
      card = record!(ctx.card, [{0, ctx.backlog}])
      lt = LeadTime.for_card(card, now: t(0))
      assert lt.segments == [] and lt.seconds == 0
    end
  end

  ## An epic -------------------------------------------------------------------

  describe "an epic" do
    setup ctx do
      epic = record!(ctx.card, [{0, ctx.todo}, {10, ctx.doing}])
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, template)
      sub = Boards.get_board!(sub.id)
      [s_todo, s_doing, s_done] = sub.columns
      one = card_fixture(s_todo, %{"title" => "Sub one"})
      two = card_fixture(s_todo, %{"title" => "Sub two"})

      one =
        record!(one, [{0, s_todo}, {10, s_doing}, {20, s_done}], completed: 20)

      two = record!(two, [{0, s_todo}, {20, s_doing}, {50, s_done}], completed: 50)
      epic_job = job!(epic, "claude", 9, 10, 40)

      %{epic: Repo.get!(Card, epic.id), one: one, two: two, epic_job: epic_job}
    end

    test "each subcard, built in the epic's job, and the subcards added up", ctx do
      lt = LeadTime.for_epic(ctx.epic, now: t(60))

      # Ready, then its own job queued.
      assert segments(lt.card) == [
               {:waiting_for_runner, 540},
               {:waiting_for_runner, 60},
               {:build, 1800},
               {:unexplained, 1200}
             ]

      assert [{one, lt_one}, {two, lt_two}] = lt.subcards
      assert one.id == ctx.one.id and two.id == ctx.two.id

      assert segments(lt_one) == [{:waiting_for_runner, 600}, {:build, 600}]
      [_, built] = lt_one.segments
      assert built.note =~ "built in its epic's job"
      assert built.refs == ["job ##{ctx.epic_job.id}"]

      # The second waited while the epic's job worked on the first, and
      # the epic's job ended before it was done.
      assert segments(lt_two) == [
               {:waiting_for_runner, 1200},
               {:build, 1200},
               {:unexplained, 600}
             ]

      [held | _] = lt_two.segments
      assert [%{job_id: id}] = held.held_by
      assert id == ctx.epic_job.id

      assert lt.total.seconds == 20 * 60 + 50 * 60
      assert lt.total.totals.build == 600 + 1200
      assert lt.total.totals.unexplained == 600
    end

    test "card_lead_time gives the epic, each subcard and the total as text", ctx do
      text = CardRecord.call(ctx.owner, ctx.epic, "card_lead_time", %{})

      assert text =~ "Lead time of ##{ctx.epic.id} “Show the id”"
      assert text =~ "still open"
      assert text =~ "By phase:"
      assert text =~ "- build: 30m"
      assert text =~ "unexplained (the record holds nothing for it)"
      assert text =~ "Its subcards (2), each from its own creation:"
      assert text =~ "Lead time of ##{ctx.one.id} “Sub one”: 20m"
      assert text =~ "The subcards added up: 1h 10m."

      sub = CardRecord.call(ctx.owner, ctx.epic, "card_lead_time", %{"card_id" => ctx.two.id})
      assert sub =~ "its pool was busy with job ##{ctx.epic_job.id} (claude)"
      assert sub =~ "built in its epic's job [job ##{ctx.epic_job.id}]"
      refute sub =~ "Its subcards"
    end
  end

  ## The tool in the chat -------------------------------------------------------

  describe "card_lead_time in the card chat" do
    setup ctx do
      card =
        record!(ctx.card, [{0, ctx.todo}, {10, ctx.doing}, {30, ctx.done}], completed: 30)

      job!(card, "claude", 9, 10, 30)
      %{card: card}
    end

    test "is offered, and its text quotes the phases with their shares", ctx do
      assert "card_lead_time" in CardRecord.names()
      text = CardRecord.call(ctx.owner, ctx.card, "card_lead_time", %{})

      assert text =~ "30m, from its creation 2026-11-05 12:00:00 UTC to done"
      assert text =~ "(no recorded deploy names it)"
      assert text =~ "- waiting for a runner: 10m (33%)"
      assert text =~ "- build: 20m (67%)"
      assert text =~ "In order (3 spans):"
      assert text =~ "no other job on its pool was running"
    end

    test "a card no job was sent on says so", ctx do
      Repo.delete_all(from(j in Job, where: j.card_id == ^ctx.card.id))
      text = CardRecord.call(ctx.owner, ctx.card, "card_lead_time", %{})
      assert text =~ "No runner job was ever sent on it"
    end

    test "a stranger is refused", ctx do
      stranger = user_fixture("lead-stranger@example.com")
      text = CardRecord.call(stranger, ctx.card, "card_lead_time", %{})
      assert text == "There is no card ##{ctx.card.id} you can see."
    end

    test "the model calls it and gets the numbers to quote", ctx do
      board = Repo.preload(ctx.board, [:columns, :fields, :tags])
      context = Context.build(%{kind: :card, board: board, card: ctx.card})

      Slipdock.AIStub.reply_sequence([
        {:tool_calls, [{"card_lead_time", %{}}]},
        "It waited 10m for a runner, then built for 20m."
      ])

      assert {:ok, "It waited 10m" <> _} =
               Assistant.chat(context, [], "Where did the time go?",
                 user: ctx.owner,
                 card: ctx.card
               )

      assert_receive {:ai_request, first}
      assert "card_lead_time" in Enum.map(first["tools"], & &1["function"]["name"])
      assert hd(first["messages"])["content"] =~ "call `card_lead_time` and quote its phases"

      assert_receive {:ai_request, second}
      tool = Enum.find(second["messages"], &(&1["role"] == "tool"))
      assert tool["name"] == "card_lead_time"
      assert tool["content"] =~ "- waiting for a runner: 10m (33%)"
    end
  end
end
