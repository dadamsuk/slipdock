defmodule Slipdock.ProfilesVerifyTest do
  @moduledoc """
  Profiles 3, the verifier's spend (#1953). With profiles on, a `docs` card
  submitted on a verifying board queues no verify job: the server accepts it
  itself, says "not verified" in its checks and the ledger, takes CI's suite
  from the evidence, and merges or holds it per the human tier. A `schema`
  or `security` card's verifier also reviews the diff for defects
  (`defect_review`), and an Important finding is a rejection. A claimed job
  carries its card's profile. With profiles off nothing changes.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Ledger, Repo, Runners, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.{Job, Runner}
  alias Slipdock.Verified.Checks

  @pr "https://github.com/acme/app/pull/9"

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Spend", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "bar_required" => true,
        "evidence_required" => true,
        "verify_pool" => "checkers",
        "profiles" => true
      })

    [_backlog, _todo, doing, done] = board.columns
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    %{owner: owner, board: board, doing: doing, done: done, builder: builder, checker: checker}
  end

  defp set(ctx, attrs) do
    {:ok, board} = Boards.update_board(Repo.get!(Boards.Board, ctx.board.id), attrs)
    board
  end

  defp card(ctx, profile, attrs \\ %{}) do
    card =
      card_fixture(ctx.doing, Map.merge(%{"title" => "Work", "bar" => "1. It reads well"}, attrs))

    if profile do
      {:ok, card} = Boards.update_card(card, %{"profile" => profile})
      card
    else
      card
    end
  end

  defp submit(card, ctx, attrs \\ %{}) do
    {:ok, card} =
      Boards.update_card(
        Repo.get!(Card, card.id),
        Map.merge(
          %{
            "completed" => true,
            "evidence" => "Rewrote the guide",
            "evidence_commit" => "abc1234",
            "evidence_suite" => %{"result" => "passed", "passed" => 12, "failed" => 0}
          },
          attrs
        ),
        actor: ctx.builder,
        by: ctx.owner
      )

    Repo.get!(Card, card.id)
  end

  defp jobs(card, kind),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == ^kind))

  defp comments(card),
    do:
      Repo.all(
        from(c in Boards.Comment, where: c.card_id == ^card.id, order_by: c.id, select: c.body)
      )

  defp merger(ctx) do
    {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "merger", "pool" => "m"})
    runner = Runners.report_kinds(runner, "merge")

    Repo.update_all(from(r in Runner, where: r.id == ^runner.id),
      set: [last_seen_at: DateTime.utc_now(:second)]
    )

    runner
  end

  describe "a docs card goes unverified" do
    test "on a push board: accepted by the server, completed, in Done, no verify job", ctx do
      card = ctx |> card("docs") |> submit(ctx)

      assert card.verify_state == "accepted"
      assert card.completed
      assert card.column_id == ctx.done.id
      refute "review" in card.flags
      assert jobs(card, "verify") == []
      assert card.verify_checks["not_verified"] == "docs"
      assert card.verify_checks["suite"] == %{"passed" => 12, "failed" => 0}
      assert card.verify_by["agent"] == "the server"
      assert card.verify_by["kind"] == "automation"
      assert Verified.who(card.verify_by) == "the server"

      # The evidence first, then the server's acceptance.
      assert [evidence, accepted] = comments(card)
      assert evidence =~ "**Evidence.**"
      assert accepted =~ "**Accepted** by the server"
      assert accepted =~ "profile docs: not verified"

      # The card panel's and the CLI's verification lines say so.
      assert {"verification", "not verified", "profile docs: no verify job runs for it"} in Checks.lines(
               card.verify_checks
             )
    end

    test "an inferred docs profile counts: a card with only docs paths", ctx do
      card = ctx |> card(nil, %{"paths" => "docs/**,README.md"}) |> submit(ctx)
      assert is_nil(card.profile)
      assert card.verify_state == "accepted"
      assert card.verify_checks["not_verified"] == "docs"
      assert jobs(card, "verify") == []
    end

    test "on a pull request board: accepted and merging per its tier (none)", ctx do
      set(ctx, %{"ship_via" => "pull_request"})
      merger(ctx)
      card = ctx |> card("docs") |> submit(ctx, %{"evidence_pr" => @pr})

      assert card.verify_state == "merging"
      refute card.completed
      assert jobs(card, "verify") == []
      assert [_merge] = jobs(card, "merge")
    end

    test "a before_merge tier for docs still holds it for a person", ctx do
      set(ctx, %{"ship_via" => "pull_request", "profile_tiers" => %{"docs" => "before_merge"}})
      merger(ctx)
      card = ctx |> card("docs") |> submit(ctx, %{"evidence_pr" => @pr})

      assert card.verify_state == "held"
      assert jobs(card, "merge") == []
      assert Boards.current_wait(card.id).purpose == "before_merge"
    end

    test "a failing suite is sent back rather than accepted unverified", ctx do
      card =
        ctx
        |> card("docs")
        |> submit(ctx, %{
          "evidence_suite" => %{"result" => "failed", "passed" => 10, "failed" => 2}
        })

      assert card.verify_state == "rejected"
      refute card.completed
      assert card.verify_note =~ "the suite: 2 failed"
      assert "the suite (2 failed)" in Checks.failing(card.verify_checks)
      assert jobs(card, "verify") == []
    end

    test "the bar is still required: an agent can't start a docs card without one", ctx do
      bare = card_fixture(hd(ctx.board.columns), %{"title" => "No bar"})
      {:ok, _} = Boards.update_card(bare, %{"profile" => "docs"})

      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(bare.id, ctx.doing.id, nil, actor: ctx.builder)

      assert message =~ "bar"
    end

    test "the ledger says not verified (docs), with no acceptor", ctx do
      card = ctx |> card("docs") |> submit(ctx)
      {:ok, ledger} = Ledger.since(ctx.board, since: 1)
      item = ledger.days |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.card.id == card.id))

      assert item.not_verified == "docs"
      assert item.accepted_by == nil
      assert "accepted" in item.events
    end

    test "a feature card is verified as before", ctx do
      card = ctx |> card("feature") |> submit(ctx)
      assert card.verify_state == "pending"
      assert [_job] = jobs(card, "verify")
    end

    test "with profiles off a docs card is verified as before", ctx do
      set(ctx, %{"profiles" => false})
      card = ctx |> card("docs") |> submit(ctx)

      assert card.verify_state == "pending"
      assert "review" in card.flags
      assert [_job] = jobs(card, "verify")
      refute Verified.not_verified?(card)
    end
  end

  describe "the mutation step (#2354)" do
    test "a fix, feature, schema or security card's verify prompt carries it", ctx do
      for profile <- ~w(fix feature schema security) do
        card =
          ctx
          |> card(profile)
          |> submit(ctx, %{"evidence_tests" => ["test/foo_test.exs", "test/bar_test.exs"]})

        [job] = jobs(card, "verify")

        assert job.prompt =~
                 "The mutation step: would the tests catch a break? This card's profile is `#{profile}`"

        assert job.prompt =~
                 "pick 3 to 5 of the most consequential lines the diff added or changed"

        assert job.prompt =~
                 "run only the card's tests (`test/foo_test.exs test/bar_test.exs`), never the whole suite"

        assert job.prompt =~ "restore the line before the next"
        assert job.prompt =~ "--check mutant:killed=lib/foo.ex:42"
        assert job.prompt =~ "--check mutant:survived=lib/foo.ex:42"

        assert job.prompt =~
                 "It is a rejection, its reason naming the mutation and the test to write"

        assert job.prompt =~ "--check mutant:pre-existing=lib/bar.ex:90"
        assert job.prompt =~ "--check mutants=n/a:\"why\""
        assert job.prompt =~ "Step: `mutating the change`"

        assert job.prompt =~
                 "`mutant:killed|survived|pre-existing=<file>:<line>:<mutation>`, `mutants=n/a:<why>`"
      end
    end

    test "only a fix is told to undo the fix", ctx do
      fix = ctx |> card("fix") |> submit(ctx)
      [job] = jobs(fix, "verify")
      assert job.prompt =~ "one mutation undoes the fix itself"
      assert job.prompt =~ "the regression test must kill it"

      feature = ctx |> card("feature") |> submit(ctx)
      [job] = jobs(feature, "verify")
      refute job.prompt =~ "undoes the fix"
    end

    test "a completion that names no tests is told so", ctx do
      card = ctx |> card("feature") |> submit(ctx)
      [job] = jobs(card, "verify")
      assert job.prompt =~ "it gave no `--tests`: say so"
    end

    test "spike, docs, no-code and profiles off get no step", ctx do
      board = Repo.get!(Boards.Board, ctx.board.id)

      spike = ctx |> card("spike") |> submit(ctx)
      [job] = jobs(spike, "verify")
      refute job.prompt =~ "The mutation step"
      refute job.prompt =~ "mutant:killed"
      refute Verified.mutation_review?(spike, board)

      refute Verified.mutation_review?(card(ctx, "docs"), board)

      no_code = %{card(ctx, "feature") | evidence_no_code: "a handbook reconcile"}
      refute Verified.mutation_review?(no_code, board)
      refute Verified.verify_prompt(no_code, board) =~ "The mutation step"

      set(ctx, %{"profiles" => false})
      card = ctx |> card("feature") |> submit(ctx)
      [job] = jobs(card, "verify")
      refute job.prompt =~ "The mutation step"
      refute Verified.mutation_review?(card, Repo.get!(Boards.Board, ctx.board.id))
    end

    test "an audit of a feature card asks for it too", ctx do
      card = ctx |> card("feature")
      board = Repo.get!(Boards.Board, ctx.board.id)
      prompt = Verified.audit_prompt(card, board)
      assert prompt =~ "The mutation step"
      assert prompt =~ "`mutants=n/a:<why>`"
    end

    test "a resubmission re-runs survivors and touched lines, and carries the rest", ctx do
      card = %{
        card(ctx, "feature")
        | verify_checks: %{"judged_at" => "abc1234", "decision" => "reject"}
      }

      step = Verified.mutation_step(card)
      assert step =~ "break again every mutant that survived last time"
      assert step =~ "--check mutant:carried=lib/foo.ex:42"
      refute Verified.mutation_step(card, audit: true) =~ "On this resubmission"
      refute Verified.mutation_step(card(ctx, "feature")) =~ "On this resubmission"
    end

    test "the builder's named mutants are listed to carry, and others tried (#2635)", ctx do
      evidence = """
      Built the export.
      - mutant:killed=lib/a.ex:42:flip > to >=
      * `mutant:survived=lib/a.ex:51:drop the nil guard:no test yet`
      mutant:killed=no place here
      mutant:bogus=lib/a.ex:1:x
      """

      card = %{card(ctx, "feature") | evidence: evidence}

      assert [
               %{"result" => "killed", "file" => "lib/a.ex", "line" => 42},
               %{"result" => "survived", "line" => 51, "note" => "no test yet"}
             ] = Verified.builder_mutants(card)

      step = Verified.mutation_step(card)
      assert step =~ "names the mutants it tried"
      assert step =~ "`mutant:killed=lib/a.ex:42:flip > to >=`"
      assert step =~ "`mutant:survived=lib/a.ex:51:drop the nil guard:no test yet`"
      assert step =~ "--check mutant:carried=<file>:<line>"
      assert step =~ "Spend your 3 to 5 on other lines"
      refute step =~ "named no mutants"
      refute step =~ "no place here"

      assert {:ok, %{"mutants" => [%{"result" => "carried"}]}} =
               Checks.parse(["mutant:carried=lib/a.ex:42"])
    end

    test "a builder that named no mutants is said to have named none", ctx do
      for evidence <- [nil, "", "Built it; CI green."] do
        card = %{card(ctx, "feature") | evidence: evidence}
        assert Verified.builder_mutants(card) == []
        step = Verified.mutation_step(card)
        assert step =~ "The builder named no mutants in its evidence"
        refute step =~ "names the mutants it tried"
      end
    end

    test "every example check the step gives parses, and only the survivor fails", ctx do
      step = Verified.mutation_step(card(ctx, "fix"))

      lines =
        ~r/--check (\S+?=[^`]+)`/
        |> Regex.scan(step, capture: :all_but_first)
        |> Enum.map(fn [line] -> String.replace(line, "\"", "") end)
        |> Enum.reject(&String.starts_with?(&1, "mutants="))

      assert length(lines) == 3
      assert {:ok, checks} = Checks.parse(lines)
      assert [_, _, _] = checks["mutants"]
      assert [survivor] = Checks.failing(checks)
      assert survivor =~ "lib/foo.ex:42"

      assert {:ok, %{"mutants" => %{"n/a" => "why"}}} = Checks.parse(["mutants=n/a:why"])
    end

    test "the profiles it runs on" do
      assert Verified.mutation_profiles() == ~w(fix feature schema security)
    end
  end

  describe "the defect review" do
    test "a schema or security card's verify prompt carries it", ctx do
      for profile <- ~w(schema security) do
        card = ctx |> card(profile) |> submit(ctx)
        [job] = jobs(card, "verify")
        assert job.prompt =~ "The defect review. This card's profile is `#{profile}`"
        assert job.prompt =~ "--check defect:important=lib/foo.ex:42"
        assert job.prompt =~ "Nit: worth saying"
        assert job.prompt =~ "never a guess from a name"
        assert job.prompt =~ "`defect:important|nit|pre-existing=<file>:<line>`"
      end
    end

    test "other profiles, and profiles off, don't", ctx do
      card = ctx |> card("feature") |> submit(ctx)
      [job] = jobs(card, "verify")
      refute job.prompt =~ "The defect review"

      set(ctx, %{"profiles" => false})
      card = ctx |> card("schema") |> submit(ctx)
      [job] = jobs(card, "verify")
      refute job.prompt =~ "The defect review"
      refute Verified.defect_review?(card, Repo.get!(Boards.Board, ctx.board.id))
    end

    test "an audit of a security card asks for it too", ctx do
      card = ctx |> card("security")
      board = Repo.get!(Boards.Board, ctx.board.id)
      assert Verified.audit_prompt(card, board) =~ "The defect review"
    end

    test "an Important finding is a rejection with it as the failing part", ctx do
      card = ctx |> card("schema") |> submit(ctx)

      {:ok, rejected} =
        Verified.decide(
          card,
          "reject",
          %{
            "reason" => "The migration drops a column the app still reads",
            "checks" => ["defect:important=priv/repo/migrations/1_drop.exs:12:drops cards.bar"]
          },
          ctx.checker,
          ctx.owner
        )

      assert rejected.verify_state == "rejected"

      assert [
               %{
                 "severity" => "important",
                 "file" => "priv/repo/migrations/1_drop.exs",
                 "line" => 12,
                 "note" => "drops cards.bar"
               }
             ] = rejected.verify_checks["defect_review"]
    end

    test "an acceptance can't carry an Important finding", ctx do
      card = ctx |> card("security") |> submit(ctx)

      assert {:error, :unprocessable_entity, message} =
               Verified.decide(
                 card,
                 "accept",
                 %{"checks" => ["ask=ok", "defect:important=lib/auth.ex:9:no check"]},
                 ctx.checker,
                 ctx.owner
               )

      assert message =~ "the defect at lib/auth.ex:9"
    end

    test "a Nit and a pre-existing finding are reported only: the card is accepted", ctx do
      card = ctx |> card("security") |> submit(ctx)

      {:ok, accepted} =
        Verified.decide(
          card,
          "accept",
          %{
            "reason" => "Checked",
            "checks" => [
              "ask=ok",
              "defect:nit=lib/auth.ex:3:a stray debug line",
              "defect:pre-existing=lib/access.ex:90"
            ]
          },
          ctx.checker,
          ctx.owner
        )

      assert accepted.verify_state == "accepted"
      assert [nit, pre] = accepted.verify_checks["defect_review"]
      assert nit["severity"] == "nit" and nit["note"] == "a stray debug line"
      assert pre == %{"severity" => "pre-existing", "file" => "lib/access.ex", "line" => 90}
    end

    test "a rejection naming only a Nit is refused: it names nothing failing", ctx do
      card = ctx |> card("schema") |> submit(ctx)

      assert {:error, :unprocessable_entity, _} =
               Verified.decide(
                 card,
                 "reject",
                 %{"reason" => "Style", "checks" => ["defect:nit=lib/a.ex:1"]},
                 ctx.checker,
                 ctx.owner
               )
    end
  end

  describe "defect_review in the checks" do
    test "lines parse with their place, case kept, and severities checked" do
      assert {:ok, %{"defect_review" => [d]}} =
               Checks.parse(["defect:Important=lib/Foo/Bar.ex:42:Loses the Row"])

      assert d == %{
               "severity" => "important",
               "file" => "lib/Foo/Bar.ex",
               "line" => 42,
               "note" => "Loses the Row"
             }

      assert {:error, message} = Checks.parse(["defect:major=lib/a.ex:1"])
      assert message =~ "important|nit|pre-existing"

      assert {:error, message} = Checks.parse(["defect:nit=lib/a.ex"])
      assert message =~ "never a guess from a name"

      assert {:error, _} = Checks.parse(["defect=lib/a.ex:1"])
    end

    test "the stored map is read back, and two findings at one place are both kept" do
      map = %{
        "defect_review" => [
          %{"severity" => "nit", "file" => "lib/a.ex", "line" => 1, "note" => "one"},
          %{severity: "nit", file: "lib/a.ex", line: 1}
        ]
      }

      assert {:ok, %{"defect_review" => [_, _]}} = Checks.parse(map)

      assert {:error, _} =
               Checks.parse(%{"defect_review" => [%{"severity" => "nit", "file" => "lib/a.ex"}]})
    end

    test "only an important finding fails, and every finding shows as a line" do
      {:ok, checks} =
        Checks.parse(["defect:important=lib/a.ex:1:bad", "defect:nit=lib/b.ex:2"])

      assert Checks.failing(checks) == ["the defect at lib/a.ex:1"]
      assert Checks.blocking(checks) == ["the defect at lib/a.ex:1"]

      assert Checks.lines(checks) == [
               {"defect", "important", "lib/a.ex:1; bad"},
               {"defect", "nit", "lib/b.ex:2"}
             ]

      assert Checks.failing_result?("important")
      refute Checks.failing_result?("nit")
    end
  end

  describe "the claimed job's profile" do
    test "claim_context carries the card's profile, inferred if need be, nil with profiles off",
         ctx do
      card = card(ctx, "schema")
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "work", prompt: "go"})
      assert Runners.claim_context(job).profile == "schema"

      inferred = card(ctx, nil, %{"paths" => "docs/**"})
      {:ok, job2} = Runners.queue(inferred, %{pool: "dev", kind: "work", prompt: "go"})
      assert Runners.job_profile(job2) == "docs"

      set(ctx, %{"profiles" => false})
      assert Runners.claim_context(job).profile == nil
      assert Runners.job_profile(%Job{card_id: nil}) == nil
    end
  end
end
