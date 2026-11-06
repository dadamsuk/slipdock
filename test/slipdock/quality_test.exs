defmodule Slipdock.QualityTest do
  @moduledoc """
  A board's quality numbers (#1796, `Slipdock.Quality`) on hand-built
  fixtures: first-time-right and rework, reopened cards, rework by handbook
  area with unmapped cards, sub-boards, the window and the one before, job
  outcomes per 100 and health incidents, and the empty board.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Handbook, Quality, Repo, Verified, Wiki}
  alias Slipdock.Boards.{Activity, Card, Comment}
  alias Slipdock.Health.Incident
  alias Slipdock.Runners.Job

  @now ~U[2026-11-01 12:00:00Z]

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Quality"}, owner: user)
    [_backlog, todo, _doing, _done] = board.columns
    %{user: user, board: board, todo: todo}
  end

  defp ago(days), do: DateTime.add(@now, -round(days * 86_400), :second)

  # A card verified `days` ago: `state` accepted (or merging, rejected),
  # with `rejections` and lane `paths`.
  defp verified!(column, days, rejections, opts \\ []) do
    card = card_fixture(column, %{"paths" => Keyword.get(opts, :paths, [])})

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [
        verify_state: Keyword.get(opts, :state, "accepted"),
        verify_at: ago(days),
        verify_rejections: rejections
      ]
    )

    card
  end

  defp reopened!(card) do
    Repo.insert!(%Activity{
      board_id: card.board_id,
      card_id: card.id,
      kind: "card",
      message: "reopened “#{card.title}”",
      actor_kind: "person",
      inserted_at: ago(40)
    })
  end

  defp job!(board, days, status, recovery \\ nil) do
    card = card_fixture(hd(Boards.get_board!(board.id).columns))

    Repo.insert!(%Job{
      card_id: card.id,
      pool: "dev",
      kind: "claude",
      prompt: "do it",
      status: status,
      recovery: recovery,
      board_id: board.id,
      root_board_id: board.root_id || board.id,
      finished_at: ago(days)
    })
  end

  defp incident!(board, days, status, attrs \\ []) do
    Repo.insert!(
      struct(
        %Incident{
          board_id: board.id,
          detector: "probe",
          fingerprint: "f#{System.unique_integer([:positive])}",
          summary: "stuck",
          status: status,
          inserted_at: ago(days),
          updated_at: ago(days)
        },
        attrs
      )
    )
  end

  defp report(board, opts \\ []), do: Quality.for_board(board, Keyword.merge([now: @now], opts))

  describe "an empty board" do
    test "has no rates rather than zeroes", %{board: board} do
      r = report(board)

      assert r.days == 30
      assert r.verified.accepted == 0
      assert r.verified.rate == nil
      assert r.verified.per_card == nil
      assert r.areas == []
      assert r.jobs.jobs == 0
      assert r.jobs.per_100 == %{timeouts: nil, failed: nil, requeues: nil, gave_up: nil}
      assert r.health == %{incidents: 0, fixed: 0, flagged: 0, cleared: 0, open: 0}
      assert Quality.sentence(r) == "30d: no cards accepted"
    end

    test "cards that never went through verification count for nothing",
         %{board: board, todo: todo} do
      card_fixture(todo, %{"completed" => true})
      assert report(board).verified.accepted == 0
    end
  end

  describe "first-time-right and rework" do
    test "counts accepted cards, those with no rejection, and rejections per card",
         %{board: board, todo: todo} do
      verified!(todo, 1, 0)
      verified!(todo, 2, 0)
      verified!(todo, 3, 2)
      verified!(todo, 4, 1, state: "merging")

      v = report(board).verified
      assert v.accepted == 4
      assert v.first_time_right == 2
      assert v.rate == 0.5
      assert v.rejections == 3
      assert v.per_card == 0.75
      assert v.reopened == 0
    end

    test "a reopened card was not right first time, rejections or not",
         %{board: board, todo: todo} do
      clean = verified!(todo, 1, 0)
      verified!(todo, 2, 0)
      reopened!(clean)

      v = report(board).verified
      assert v.accepted == 2
      assert v.first_time_right == 1
      assert v.reopened == 1
    end

    test "cards rejected in the window and not yet accepted are in rework",
         %{board: board, todo: todo} do
      verified!(todo, 1, 1, state: "rejected")
      verified!(todo, 45, 1, state: "rejected")
      verified!(todo, 2, 0, state: "pending")

      v = report(board).verified
      assert v.in_rework == 1
      assert v.accepted == 0
    end

    test "only the window counts, and the window before is the trend",
         %{board: board, todo: todo} do
      verified!(todo, 5, 0)
      verified!(todo, 40, 1)
      verified!(todo, 50, 0)
      verified!(todo, 70, 0)

      r = report(board)
      assert r.verified.accepted == 1
      assert r.verified.rate == 1.0
      assert r.previous.accepted == 2
      assert r.previous.rate == 0.5
      assert Quality.sentence(r) =~ "100% right first time (1 of 1) ↑"

      assert report(board, days: "7").verified.accepted == 1
      assert report(board, days: 3).verified.accepted == 0
      assert report(board, days: "nonsense").days == 30
      assert report(board, days: 9999).days == 365
      assert report(board, days: 0).days == 1
    end

    test "the window takes in its last second: a card accepted just now counts",
         %{board: board, todo: todo} do
      verified!(todo, 0, 0)
      card = card_fixture(todo)

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [verify_state: "accepted", verify_at: DateTime.utc_now(:second)]
      )

      assert report(board).verified.accepted == 1
      assert report(board).previous.accepted == 0
      # Without :now, today: both are within its 30 days.
      assert Quality.for_board(board).verified.accepted == 2
    end

    test "sub-boards' cards count, however deep; a sub-board counts only its own",
         %{board: board, todo: todo} do
      {:ok, t} = Boards.find_template(nil, "Simple")
      epic = card_fixture(todo, %{"title" => "Epic"})
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      task = card_fixture(hd(sub.columns), %{"title" => "Task"})
      {:ok, deeper} = sub_board(task, t)
      deeper = Boards.get_board!(deeper.id)

      verified!(todo, 1, 0)
      verified!(hd(sub.columns), 1, 1)
      verified!(hd(deeper.columns), 1, 2)

      assert report(board).verified.accepted == 3
      assert report(board).verified.rejections == 3
      assert report(sub).verified.accepted == 2
      assert report(deeper).verified.accepted == 1
      assert Enum.sort(Quality.tree_ids(board)) == Enum.sort([board.id, sub.id, deeper.id])
    end
  end

  describe "rework by area" do
    test "without a handbook every card is unmapped", %{board: board, todo: todo} do
      verified!(todo, 1, 1, paths: ["lib/a.ex"])
      verified!(todo, 1, 0)

      assert [%{code: nil, title: "unmapped", cards: 2, rejections: 1, rate: 0.5}] =
               report(board).areas
    end

    test "each card goes to the page covering most of its paths, unmapped otherwise",
         %{user: user, board: board, todo: todo} do
      {:ok, _} = Handbook.install(user, board)
      pages = Handbook.find(board).pages
      data = Enum.find(pages, &(&1.title == "Data model"))
      ux = Enum.find(pages, &(&1.title == "UX & UI"))

      {:ok, _} =
        Wiki.update_page(data, %{
          "front_matter" => "---\nhandbook: data-model\ncovers: [priv/repo/**]\n---\n"
        })

      {:ok, _} =
        Wiki.update_page(ux, %{
          "front_matter" => "---\nhandbook: ux\ncovers: [lib/app_web/**]\n---\n"
        })

      verified!(todo, 1, 2, paths: ["priv/repo/migrations/1.exs"])
      verified!(todo, 1, 1, paths: ["priv/repo/a.exs", "priv/repo/b.exs", "lib/app_web/x.ex"])
      verified!(todo, 1, 0, paths: ["lib/app_web/live/y.ex"])
      verified!(todo, 1, 1, paths: ["somewhere/else.txt"])
      verified!(todo, 1, 0)

      areas = report(board).areas

      assert [
               %{code: dcode, title: "Data model", cards: 2, rejections: 3, rate: +0.0},
               %{code: nil, title: "unmapped", cards: 2, rejections: 1, rate: 0.5},
               %{code: ucode, title: "UX & UI", cards: 1, rejections: 0, rate: 1.0}
             ] = areas

      assert dcode == data.code
      assert ucode == ux.code
    end
  end

  describe "jobs" do
    test "timeouts, failures, requeues and give-ups per 100 finished jobs", %{board: board} do
      for _ <- 1..6, do: job!(board, 1, "done")
      job!(board, 1, "timeout")
      job!(board, 2, "failed")
      job!(board, 2, "done", "requeued")
      job!(board, 3, "done", "gave_up")
      job!(board, 45, "timeout")

      j = report(board).jobs
      assert j.jobs == 10
      assert %{timeouts: 1, failed: 1, requeues: 1, gave_up: 1} = j
      assert j.per_100 == %{timeouts: 10.0, failed: 10.0, requeues: 10.0, gave_up: 10.0}
      assert Quality.sentence(report(board)) =~ "10 jobs: 10.0 timeouts"
    end

    test "a requeue later finished counts as a requeue", %{board: board} do
      job!(board, 1, "done", "requeued_before_done")
      assert report(board).jobs.requeues == 1
    end

    test "jobs still running count for nothing", %{board: board} do
      Repo.insert!(%Job{
        pool: "dev",
        kind: "claude",
        prompt: "p",
        status: "running",
        card_id: card_fixture(hd(Boards.get_board!(board.id).columns)).id,
        board_id: board.id,
        root_board_id: board.id
      })

      assert report(board).jobs.jobs == 0
    end
  end

  describe "health" do
    test "incidents raised in the window, fixed versus flagged", %{board: board} do
      incident!(board, 1, "fixed")
      incident!(board, 1, "fixed")
      incident!(board, 2, "flagged", flagged_at: ago(2))
      incident!(board, 2, "handled", flagged_at: ago(2))
      incident!(board, 3, "cleared")
      incident!(board, 3, "open")
      incident!(board, 60, "flagged", flagged_at: ago(60))

      assert report(board).health == %{incidents: 6, fixed: 2, flagged: 2, cleared: 1, open: 1}
    end

    test "a sub-board counts the incidents about its own cards",
         %{board: board, todo: todo} do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card_fixture(todo), t)
      sub = Boards.get_board!(sub.id)
      task = card_fixture(hd(sub.columns))

      incident!(board, 1, "fixed", card_id: task.id)
      incident!(board, 1, "flagged", flagged_at: ago(1))

      assert report(sub).health.incidents == 1
      assert report(board).health.incidents == 2
    end
  end

  describe "rejections by part and rule (#1798)" do
    defp agent(user, label),
      do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id, agent: label}

    # A card submitted by one agent and rejected by another, through
    # `Verified.decide/5`: the comment it posts is what is counted.
    defp rejected!(ctx, params) do
      [_backlog, _todo, doing, _done] = ctx.board.columns
      card = card_fixture(doing)

      {:ok, card} =
        Boards.update_card(card, %{"completed" => true},
          actor: agent(ctx.user, "builder"),
          by: ctx.user
        )

      {:ok, _} = Verified.decide(card, "reject", params, agent(ctx.user, "checker"), ctx.user)
      card
    end

    defp comment!(card, body, at) do
      Repo.insert!(%Comment{card_id: card.id, body: body, inserted_at: at, updated_at: at})
    end

    defp rejections(board), do: Quality.for_board(board).rejections

    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
      {:ok, _} = Handbook.install(ctx.user, board)
      ux = Enum.find(Handbook.find(board).pages, &(&1.title == "UX & UI"))

      {:ok, _} =
        Wiki.update_page(ux, %{
          "body" =>
            "# UX & UI\n\n## Rules\n\n" <>
              "- **UX-1** must · judgement · Colours come from the tokens.\n" <>
              "- **UX-2** should · judgement · Say it once.\n"
        })

      %{board: Boards.get_board!(board.id), ux: ux}
    end

    test "counts each rejection's failing parts from its verdict, and rules by id with their page",
         ctx do
      rejected!(ctx, %{
        "reason" => "Not yet",
        "checks" => ["bar:1=ok", "bar:2=fail:no footer", "rule:UX-1=broken:hex", "ask=ok"]
      })

      rejected!(ctx, %{
        "reason" => "Again",
        "checks" => ["rule:UX-1=broken", "rule:UX-2=broken", "handbook_line=disputed:W-3"]
      })

      rejected!(ctx, %{"reason" => "Short", "checks" => ["ask=misses", "suite=10:2"]})

      r = rejections(ctx.board)
      assert r.rejections == 3
      assert r.unparted == 0
      assert r.disputed_lines == 1

      assert r.by_part == [
               %{part: "rules", count: 2},
               %{part: "ask", count: 1},
               %{part: "bar", count: 1},
               %{part: "suite", count: 1},
               %{part: "handbook_line", count: 1}
             ]

      code = ctx.ux.code

      assert [
               %{id: "UX-1", count: 2, severity: "must", page: %{code: ^code, title: "UX & UI"}},
               %{id: "UX-2", count: 1, severity: "should", page: %{code: ^code}}
             ] = r.by_rule
    end

    test "a rejection given no parts counts the ones its reason cites", ctx do
      rejected!(ctx, %{"reason" => "bar 3: the totals are wrong\nUX-1: a hex colour"})

      r = rejections(ctx.board)
      assert r.unparted == 0
      assert Enum.map(r.by_part, & &1.part) == ["bar", "rules"]
      assert [%{id: "UX-1", count: 1}] = r.by_rule
    end

    test "a person's rejection that names no part is unparted", ctx do
      [_backlog, _todo, doing, _done] = ctx.board.columns
      card = card_fixture(doing)

      {:ok, card} =
        Boards.update_card(card, %{"completed" => true},
          actor: agent(ctx.user, "builder"),
          by: ctx.user
        )

      {:ok, _} =
        Verified.decide(
          card,
          "reject",
          %{"reason" => "Not what I meant"},
          Actor.web(ctx.user),
          ctx.user
        )

      assert %{rejections: 1, unparted: 1, by_part: [], by_rule: []} = rejections(ctx.board)
    end

    test "an older reason-only rejection is unparted, whatever its reason cites", ctx do
      [_backlog, todo | _] = ctx.board.columns
      card = card_fixture(todo)
      comment!(card, "**Rejected** by checker.\n\nbar 2: no footer", ago_now(20))

      r = rejections(ctx.board)
      assert r.rejections == 1
      assert r.unparted == 1

      # The same reason since verdicts were kept in parts counts as bar.
      comment!(card, "**Rejected** by checker.\n\nbar 2: no footer", ago_now(0))

      assert %{rejections: 2, unparted: 1, by_part: [%{part: "bar", count: 1}]} =
               rejections(ctx.board)
    end

    test "a rule the handbook no longer has keeps its id, with no page", ctx do
      rejected!(ctx, %{"reason" => "Gone", "checks" => ["rule:OLD-9=broken"]})
      assert [%{id: "OLD-9", page: nil, severity: nil}] = rejections(ctx.board).by_rule
    end

    test "only the window counts; acceptances and other comments are not rejections", ctx do
      [_backlog, todo | _] = ctx.board.columns
      card = card_fixture(todo)
      comment!(card, "**Rejected** by checker.\n\nOld\n\nChecks:\n\n- bar 1: fail", ago_now(45))
      comment!(card, "**Accepted** by checker.\n\nFine\n\nChecks:\n\n- bar 1: ok", ago_now(1))
      comment!(card, "Rejected it, in words", ago_now(1))

      assert %{rejections: 0, by_part: []} = rejections(ctx.board)
    end

    test "audits agreed and disagreed in the window", ctx do
      [_backlog, todo | _] = ctx.board.columns
      card = card_fixture(todo)
      comment!(card, "**Audit: agrees** with the acceptance, by auditor.", ago_now(1))
      comment!(card, "**Audit: disagrees** with the acceptance, by auditor.\n\nbar 2", ago_now(2))
      comment!(card, "**Audit: disagrees** with the acceptance, by auditor.", ago_now(2))
      comment!(card, "**Audit: agrees** with the acceptance, by auditor.", ago_now(50))

      assert Quality.for_board(ctx.board).audits == %{audits: 3, agreed: 1, disagreed: 2}
    end

    test "rejection_parts/3 reads a Checks block line by line" do
      body =
        "**Rejected** by x.\n\nwhy\n\nChecks:\n\n" <>
          "- the ask: ok\n- bar 1: ok\n- bar 2: fail — no footer: really\n" <>
          "- suite: 410 passed, 2 failed\n- UX-4 must: broken — hex\n- ARCH-1: n/a\n" <>
          "- Handbook line: disputed — W-3"

      assert Quality.rejection_parts(body, @now, nil) == [
               {"bar", "2"},
               {"suite", nil},
               {"rules", "UX-4"},
               {"handbook_line", nil}
             ]

      ok_suite = "**Rejected** by x.\n\nwhy\n\nChecks:\n\n- suite: 410 passed, 0 failed"
      assert Quality.rejection_parts(ok_suite, @now, nil) == []
    end
  end

  # Days before now, for the rows `Quality.for_board/2` reads without `:now`.
  defp ago_now(days),
    do: DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)
end
