defmodule Slipdock.FindingsLessonsTest do
  @moduledoc """
  One finding per lesson (#1941, W-2310 §Findings): a lesson said again on
  the same card counts on its finding, one said on another card of the tree
  is merged into the open one there, `rule` and `handbook-wrong` stay per
  card, a `tooling (runner)` item is kept with the runner and out of the
  board's list, and `dedupe/2` applies the same to findings already kept.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Findings, Repo, Runners}
  alias Slipdock.Findings.{Block, Finding, Lesson}

  # The eight write-ups of one bug (#2115) on 2026-11-08, findings #400 #404
  # #407 #413 #418 #424 #430 #437, in the order they came.
  @pre_push [
    {"gotcha",
     "`mix pre_push` hardcodes `MIX_TEST_PARTITION=_pre_push`, and that database is shared by every worktree on the machine. A worktree whose branch has different migrations fails it with `duplicate_table`. Run the steps by hand with a partition of your own."},
    {"tooling",
     "the shared `_pre_push` test database can hold another branch's migration (`overseer_settings` already exists), which fails `mix pre_push`'s repo-check step before any test runs. Run those files with your own `MIX_TEST_PARTITION` instead."},
    {"tooling",
     "every worktree on a host shares the `_pre_push` test database. A branch with another version of a migration leaves it failing with \"relation already exists\". `MIX_TEST_PARTITION=_pre_push MIX_BUILD_PATH=_build/pre_push/test mix ecto.drop` mends it."},
    {"gotcha",
     "`mix pre_push` always tests in the `_pre_push` database, which every worktree shares. One whose migrations differ fails with `duplicate_table`. Run its repo-check step with `MIX_TEST_PARTITION=_<own>` instead."},
    {"tooling",
     "`TEST_DATABASE_URL` overrides `MIX_TEST_PARTITION`, and every worktree shares `mix pre_push`'s `_pre_push` test database. A migration another branch ran there (`overseer_settings` exists) fails the repo-checks step with `duplicate_table`. `TEST_DATABASE_URL=…/slipdock_test_<own> mix pre_push` gets around it."},
    {"gotcha",
     "the `_pre_push` test database is shared by every worktree on a machine. A branch whose migration later changed its version (`overseer_settings`) leaves a table that makes `mix pre_push`'s repo checks fail with `42P07 duplicate_table`. `dropdb slipdock_test_pre_push` (port 5434) fixes it, and so does `slipdock_test<partition>` for `mix test`."},
    {"tooling",
     "a shared `MIX_TEST_PARTITION=_pre_push` database that has run a migration later re-dated on main (#2095) fails `mix pre_push` with a duplicate column: `MIX_TEST_PARTITION=_pre_push MIX_ENV=test mix ecto.drop` fixes it"},
    {"tooling",
     "a lane worktree's default test database (no `MIX_TEST_PARTITION`) can carry another branch's migrations (`overseer_settings already exists`); a partition of its own (`MIX_TEST_PARTITION=_cNNNN mix ecto.reset`) runs clean"}
  ]

  setup do
    owner = user_fixture()
    board = Boards.get_board!(board_fixture(%{"name" => "Lessons"}, owner: owner).id)
    [_backlog, doing | _] = board.columns
    one = card_fixture(doing, %{"title" => "One"})
    two = card_fixture(doing, %{"title" => "Two"})
    %{owner: owner, board: board, doing: doing, one: one, two: two}
  end

  defp say(card, owner, block) do
    {:ok, comment} = Boards.add_comment(card, block, by: owner)
    comment
  end

  defp block(items),
    do: "- Handbook: no change\n- Findings:\n" <> Enum.map_join(items, "\n", &"  - #{&1}")

  defp all(board),
    do: Repo.all(from(f in Finding, where: f.board_id == ^board.id, order_by: f.id))

  defp open(board), do: Enum.filter(all(board), &(&1.status == "open"))

  describe "Lesson" do
    test "normalises case, whitespace, backticks and trailing punctuation" do
      assert Lesson.normalise("  Run `mix format`\n  TWICE.  ") == "run mix format twice"
      assert Lesson.same?("the CLI lacks `--paths-from`!", "The CLI lacks --paths-from")
      assert Lesson.same?("a b;", "a   b")
      refute Lesson.same?("run it twice", "run it once")
    end

    test "reads every #id and commit sha alike, but not a word made of hex letters" do
      assert Lesson.same?("fixed in #12", "Fixed in #3401")
      assert Lesson.same?("broke at 40002e65c256", "broke at 1a2b3c4d")
      assert Lesson.normalise("see 40002e65c256d2026b39f95193c796dcfdf17cbe") == "see <sha>"
      assert Lesson.normalise("the page was defaced") == "the page was defaced"
      refute Lesson.same?("fixed in #12", "fixed in W-12")
    end

    test "near?: the same lesson in other words, by most words in common" do
      a =
        "swimlane LiveView tests need ?empty=show or cell indexes point past hidden empty rows and the move silently does nothing"

      b =
        "swimlane LiveView tests need `?empty=show`. Without it, cell indexes point past hidden empty rows and the move does nothing, with no error."

      assert Lesson.near?(a, b)
      refute Lesson.same?(a, b)
      refute Lesson.near?(a, "running mix pre_push beside mix test timed out a Task.await")
      assert Lesson.overlap("", "") == 0.0
    end

    test "similarity: telling words only, a code word weighing three" do
      # The common words count for nothing, so two texts of only those are not alike.
      assert Lesson.similarity("it is run when it is done", "what is run, and when") == 0.0
      assert Lesson.similarity("", nil) == 0.0
      assert Lesson.similarity("the installed CLI lags", "the installed CLI lags") == 1.0

      # One shared code word (3 of 3 + 3 + 1 + 1) outweighs one shared plain word.
      code = Lesson.similarity("`mix_audit` fails offline", "`mix_audit` flakes nightly")
      plain = Lesson.similarity("audit fails offline", "audit flakes nightly")
      assert_in_delta code, 6 / 10, 0.001
      assert_in_delta plain, 2 / 6, 0.001

      # "worktrees" meets "worktree", and "branch's" meets "branch".
      assert Lesson.similarity(
               "worktrees share a branch's database",
               "a worktree shares the branch database"
             ) ==
               1.0
    end

    test "alike?: a rewording across cards, but not another lesson in shared words" do
      # Findings #206 and #217, two cards' write-ups of one macOS failure.
      a =
        "`hook_prompt_test.exs` fails on macOS because `after-job-hook.sh` uses GNU `date -Is`, so `mix pre_push` stops there on a Mac"

      b =
        "`test/slipdock/runners/hook_prompt_test.exs` fails under macOS's BSD `date` (`date -Is`), so `mix pre_push` stops at the repo checks on a Mac; CI's Linux passes it"

      assert Lesson.alike?(a, b)

      refute Lesson.alike?(
               "`mix pre_push` stops at the first step that fails, so a red format check hides the rest",
               "`mix pre_push` takes about 2½ minutes; start it alongside the tests you changed"
             )

      assert Lesson.alike?("Keep it once.", "keep it once")
      refute Lesson.alike?("", "keep it once")
    end
  end

  describe "on the same card" do
    test "a repeat in another comment counts on the open finding, and makes no row", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: run `mix format` twice"]))
      say(ctx.one, ctx.owner, block(["gotcha: Run mix format   twice."]))

      assert [%Finding{count: 2, comment_ids: [_, _]}] = all(ctx.board)
    end

    test "the same item twice in one comment counts once", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: run it twice", "gotcha: Run it twice."]))
      assert [%Finding{count: 1}] = all(ctx.board)
    end

    test "a different kind is a different finding", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: run it twice", "process: run it twice"]))
      assert length(all(ctx.board)) == 2
    end

    test "one a person has triaged is not made again or counted", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: run it twice"]))
      [f] = all(ctx.board)
      {:ok, _} = Findings.triage(f, "dismiss")

      say(ctx.one, ctx.owner, block(["gotcha: run it twice."]))
      assert [%Finding{status: "dismissed", count: 1}] = all(ctx.board)
    end

    test "parsing a comment again takes back what it added first", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: run it twice"]))
      second = say(ctx.one, ctx.owner, block(["gotcha: run it twice"]))

      {:ok, _} = Findings.from_comment(second)
      {:ok, _} = Findings.from_comment(second)
      assert [%Finding{count: 2}] = all(ctx.board)
    end

    test "deleting a comment takes back its count; the last one takes the finding", ctx do
      first = say(ctx.one, ctx.owner, block(["gotcha: run it twice"]))
      second = say(ctx.one, ctx.owner, block(["gotcha: run it twice"]))

      {:ok, _} = Boards.delete_comment(first)
      assert [%Finding{count: 1, comment_ids: [id], comment_id: id}] = all(ctx.board)
      assert id == second.id

      {:ok, _} = Boards.delete_comment(second)
      assert all(ctx.board) == []
    end

    # #1923's submission, evidence and restatement, as they were posted.
    test "#1923's comments yield three findings", ctx do
      first = """
      Handbook: updated W-1944 §Specification/Cards (swimlane drag refusal)
      Findings:
      - gotcha: swimlane LiveView tests need ?empty=show or cell indexes point past hidden empty rows and the move silently does nothing
      - tooling: the installed CLI rejects handbook --paths-from

      Commit: `40002e65c256d2026b39f95193c796dcfdf17cbe` on `card-1923`
      """

      second = """
      - Handbook: updated W-1944 §Specification/Cards
      - Findings:
        - gotcha: swimlane LiveView tests need `?empty=show`. Without it, cell indexes point past hidden empty rows and the move does nothing, with no error.
        - gotcha: running `mix pre_push` beside a full `mix test` timed out a 5 s `Task.await` in `fixtures_test.exs`. It passed when run alone.
        - tooling: the installed CLI rejects `handbook --paths-from`
      - Follow-ups: none
      """

      say(ctx.one, ctx.owner, first)
      say(ctx.one, ctx.owner, second)
      say(ctx.one, ctx.owner, first)

      counts = ctx.board |> all() |> Enum.map(&{&1.kind, &1.count}) |> Enum.sort()
      assert counts == [{"gotcha", 1}, {"gotcha", 3}, {"tooling", 3}]
    end
  end

  describe "across cards" do
    test "the same lesson on another card is merged into the open one, which counts it", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: the fixture is always the same user (#12)"]))
      say(ctx.two, ctx.owner, block(["gotcha: The fixture is always the same user (#34)."]))

      [kept, repeat] = all(ctx.board)
      assert %{status: "open", count: 2, card_id: one} = kept
      assert one == ctx.one.id
      assert %{status: "merged", merged_into_id: into, card_id: two} = repeat
      assert into == kept.id and two == ctx.two.id

      assert {:ok, [listed]} = Findings.list(ctx.board)
      assert listed.id == kept.id
      assert Enum.map(listed.cards, & &1.id) == [ctx.one.id, ctx.two.id]
      assert Enum.map(Findings.get(kept.id).cards, & &1.id) == [ctx.one.id, ctx.two.id]
    end

    test "a restatement in other words is merged too, its note saying how alike", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: the fixture is always the same user (#12)"]))
      say(ctx.two, ctx.owner, block(["gotcha: The fixture is always the same user (#34)."]))
      [kept, same] = all(ctx.board)
      assert same.note == "same lesson as ##{kept.id}, in the same words"

      three = card_fixture(ctx.doing, %{"title" => "Three"})

      say(
        three,
        ctx.owner,
        block(["tooling: the user fixture always returns the same user"])
      )

      [_, _, reworded] = all(ctx.board)
      assert %{status: "merged", merged_into_id: into, cause: "same-lesson"} = reworded
      assert into == kept.id
      assert reworded.note =~ ~r/^same lesson as ##{kept.id}, reworded \(\d+% alike\)$/
      assert Repo.get!(Finding, kept.id).count == 3
    end

    test "findings that share some words but are other lessons stay apart", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: run mix format twice before pushing"]))
      say(ctx.two, ctx.owner, block(["gotcha: mix test needs its own partition before you push"]))

      three = card_fixture(ctx.doing, %{"title" => "Three"})

      say(
        three,
        ctx.owner,
        block(["gotcha: `mix pre_push` stops at the first step that fails, so run the tests too"])
      )

      assert length(open(ctx.board)) == 3
    end

    test "the eight write-ups of the _pre_push bug fold mostly into one", ctx do
      for {{kind, text}, i} <- Enum.with_index(@pre_push) do
        card = card_fixture(ctx.doing, %{"title" => "Card #{i}"})
        say(card, ctx.owner, block(["#{kind}: #{text}"]))
      end

      [first | _] = all(ctx.board)

      assert [{kept, 6} | rest] =
               ctx.board |> open() |> Enum.map(&{&1.id, &1.count})

      assert kept == first.id
      # The two left are for the model to group (#2118).
      assert Enum.map(rest, &elem(&1, 1)) == [1, 1]

      merged = Enum.filter(all(ctx.board), &(&1.status == "merged"))
      assert length(merged) == 5
      assert Enum.all?(merged, &(&1.merged_into_id == first.id and &1.note =~ "reworded"))
      # A gotcha and a tooling item are one lesson across cards.
      assert merged |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort() == ["gotcha", "tooling"]
    end

    test "a match on a repeat already merged counts on the open finding", ctx do
      [{_, first}, {_, second}, {_, third} | _] = @pre_push
      # The third matches the second (merged into the first) better than the first.
      assert Lesson.similarity(third, second) >= Lesson.alike_at()
      refute Lesson.similarity(third, first) >= Lesson.alike_at()

      for {text, i} <- Enum.with_index([first, second, third]) do
        card = card_fixture(ctx.doing, %{"title" => "Card #{i}"})
        say(card, ctx.owner, block(["tooling: #{text}"]))
      end

      assert [%{count: 3}] = open(ctx.board)
    end

    test "a sub-board's card merges into its root's", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.one, t)
      sub = Boards.get_board!(sub.id)
      subcard = card_fixture(hd(sub.columns), %{"title" => "Below"})

      say(ctx.two, ctx.owner, block(["gotcha: keep it once"]))
      say(subcard, ctx.owner, block(["gotcha: keep it once"]))

      assert [%{count: 2, card_id: two}] = open(ctx.board)
      assert two == ctx.two.id
    end

    test "rule and handbook-wrong items are never merged across cards", ctx do
      items = ["rule: every MCP tool gets a docs test", "handbook-wrong: W-1950 says async"]
      say(ctx.one, ctx.owner, block(items))
      say(ctx.two, ctx.owner, block(items))

      reworded = [
        "rule: each MCP tool gets a docs test",
        "handbook-wrong: W-1950 says it is async"
      ]

      say(card_fixture(ctx.doing, %{"title" => "Three"}), ctx.owner, block(reworded))

      assert ctx.board |> open() |> Enum.map(& &1.count) == [1, 1, 1, 1, 1, 1]

      # Nor does an agent's gotcha fold into a rule candidate in the same words.
      say(
        card_fixture(ctx.doing, %{"title" => "Four"}),
        ctx.owner,
        block(["gotcha: every MCP tool gets a docs test"])
      )

      assert length(open(ctx.board)) == 7
    end

    test "nor into one a person has triaged", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: keep it once"]))
      [f] = all(ctx.board)
      {:ok, _} = Findings.triage(f, "dismiss")

      say(ctx.two, ctx.owner, block(["gotcha: keep it once"]))
      assert [%{card_id: two, status: "open"}] = open(ctx.board)
      assert two == ctx.two.id
    end

    test "deleting the repeat's comment takes back its count", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: keep it once"]))
      repeat = say(ctx.two, ctx.owner, block(["gotcha: keep it once"]))

      {:ok, _} = Boards.delete_comment(repeat)
      assert [%{count: 1, card_id: one}] = all(ctx.board)
      assert one == ctx.one.id
    end

    test "the system's own findings are untouched: a repeat still counts by cause", ctx do
      attrs = %{
        card: ctx.one,
        source: "timeout",
        kind: "process",
        text: "job #1 timed out",
        cause: "t"
      }

      {:ok, _} = Findings.record(attrs)
      {:ok, f} = Findings.record(%{attrs | text: "job #2 timed out"})
      assert f.count == 2
      assert f.lesson == "job #n timed out"
    end
  end

  describe "scope" do
    test "`tooling (runner)` is runner-scoped; on any other kind it is ignored" do
      assert [
               %{kind: "tooling", scope: "runner", text: "the CLI lags"},
               %{kind: "tooling", scope: "board", text: "pwsh is missing in CI"},
               %{kind: "gotcha", scope: "board", text: "not a machine thing"}
             ] =
               Block.parse("""
               - Findings:
                 - tooling (runner): the CLI lags
                 - tooling: pwsh is missing in CI
                 - gotcha (runner): not a machine thing
               """)
    end

    test "is kept with the runner whose job the pass is in, the epic's when the card has none",
         ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "laptop", "pool" => "dev"})
      {:ok, job} = Runners.queue(ctx.one, %{pool: "dev", kind: "claude", prompt: "go"})
      Runners.claim(runner)

      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.one, t)
      subcard = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Sub"})

      say(subcard, ctx.owner, block(["tooling (runner): the installed CLI lacks --paths-from"]))

      assert [%Finding{scope: "runner", runner_id: runner_id, job_id: job_id}] = all(ctx.board)
      assert runner_id == runner.id and job_id == job.id
    end

    test "is out of the default list; scope runner or all shows it; a bad scope is refused",
         ctx do
      say(
        ctx.one,
        ctx.owner,
        block(["tooling (runner): the CLI lags", "gotcha: a project thing"])
      )

      assert {:ok, [%{kind: "gotcha"}]} = Findings.list(ctx.board)
      assert {:ok, [%{kind: "gotcha"}]} = Findings.list(ctx.board, %{"scope" => "board"})
      assert {:ok, [%{kind: "tooling"}]} = Findings.list(ctx.board, %{"scope" => "runner"})
      assert {:ok, [_, _]} = Findings.list(ctx.board, %{"scope" => "all"})

      assert {:error, "scope is board, runner or all"} =
               Findings.list(ctx.board, %{"scope" => "x"})
    end

    test "a card's open count is unchanged by scope", ctx do
      say(
        ctx.one,
        ctx.owner,
        block(["tooling (runner): the CLI lags", "gotcha: a project thing"])
      )

      assert Findings.open_count(ctx.one) == 2
    end

    test "merges across cards only with the same scope and runner", ctx do
      say(ctx.one, ctx.owner, block(["tooling (runner): the CLI lags"]))
      say(ctx.two, ctx.owner, block(["tooling: the CLI lags"]))
      assert length(open(ctx.board)) == 2

      three = card_fixture(ctx.doing, %{"title" => "Three"})
      say(three, ctx.owner, block(["tooling (runner): the CLI lags"]))

      assert ctx.board |> open() |> Enum.map(&{&1.scope, &1.count}) == [
               {"runner", 2},
               {"board", 1}
             ]

      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "desk", "pool" => "dev"})
      four = card_fixture(ctx.doing, %{"title" => "Four"})
      {:ok, _job} = Runners.queue(four, %{pool: "dev", kind: "claude", prompt: "go"})
      Runners.claim(runner)
      say(four, ctx.owner, block(["tooling (runner): the CLI lags"]))

      assert length(open(ctx.board)) == 3
    end
  end

  describe "dedupe/2" do
    # Findings kept before #1941: one row per comment, as `insert/3` makes here.
    defp insert(board, card, kind, text, comment_id) do
      %Finding{
        board_id: board.id,
        card_id: card.id,
        comment_id: comment_id,
        comment_ids: [comment_id],
        kind: kind,
        source: "agent",
        text: text,
        lesson: Lesson.normalise(text)
      }
      |> Repo.insert!()
    end

    setup ctx do
      c1 = say(ctx.one, ctx.owner, "first").id
      c2 = say(ctx.one, ctx.owner, "second").id
      c3 = say(ctx.two, ctx.owner, "third").id

      %{
        a:
          insert(
            ctx.board,
            ctx.one,
            "gotcha",
            "swimlane tests need ?empty=show or the move does nothing",
            c1
          ),
        b:
          insert(
            ctx.board,
            ctx.one,
            "gotcha",
            "swimlane tests need `?empty=show`, or the move does nothing.",
            c2
          ),
        c:
          insert(
            ctx.board,
            ctx.two,
            "gotcha",
            "Swimlane tests need ?empty=show or the move does nothing",
            c3
          ),
        d: insert(ctx.board, ctx.one, "rule", "every tool gets a docs test", c1),
        e: insert(ctx.board, ctx.two, "rule", "every tool gets a docs test", c3),
        f: insert(ctx.board, ctx.two, "tooling", "the installed CLI lags", c3),
        c2: c2
      }
    end

    test "a dry run says what it would merge and changes nothing", ctx do
      before = all(ctx.board)
      pairs = Findings.dedupe(ctx.board, dry_run: true)

      assert Enum.map(pairs, fn {r, i} -> {r.id, i.id} end) == [
               {ctx.b.id, ctx.a.id},
               {ctx.c.id, ctx.a.id}
             ]

      assert all(ctx.board) == before
    end

    test "merges each card's repeats, then each lesson across cards, rules aside", ctx do
      Findings.dedupe(ctx.board)

      assert ctx.board |> open() |> Enum.map(&{&1.id, &1.count}) ==
               [{ctx.a.id, 3}, {ctx.d.id, 1}, {ctx.e.id, 1}, {ctx.f.id, 1}]

      b = Repo.get!(Finding, ctx.b.id)
      assert %{status: "merged", merged_into_id: a} = b
      assert a == ctx.a.id
      assert b.note =~ "dedupe"
      assert ctx.c2 in Repo.get!(Finding, ctx.a.id).comment_ids

      # Run again, nothing is left to merge; a person can reopen one.
      assert Findings.dedupe(ctx.board) == []
      {:ok, _} = Findings.triage(b, "reopen")
      assert Repo.get!(Finding, ctx.a.id).count == 2
    end

    test "after it, each comment's count is still its own to take back", ctx do
      Findings.dedupe(ctx.board)
      # The second comment, edited to say nothing, takes back the one it added.
      comment = Repo.get!(Slipdock.Boards.Comment, ctx.c2)
      {:ok, _} = Findings.from_comment(comment)
      {:ok, _} = Findings.from_comment(comment)
      assert %{count: 2, status: "open"} = Repo.get!(Finding, ctx.a.id)
    end

    test "dedupe_named reports by board code, and refuses an unknown board", ctx do
      report = Findings.dedupe_named(ctx.board.code, dry_run: true)
      assert report =~ "Lessons: would merge 2 repeated findings"
      assert report =~ "##{ctx.b.id} into ##{ctx.a.id} (gotcha)"
      assert {:error, "no board \"no-such-board-x\""} = Findings.dedupe_named("no-such-board-x")
    end

    test "the mix task runs it", ctx do
      report =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Slipdock.Findings.Dedupe.run([ctx.board.code])
        end)

      assert report =~ "Lessons: merged 2 repeated findings"
      assert Repo.get!(Finding, ctx.a.id).count == 3

      assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Slipdock.Findings.Dedupe.run([]) end
    end
  end
end
