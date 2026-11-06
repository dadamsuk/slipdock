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

    test "only on the same text: a restatement in other words is its own finding", ctx do
      say(ctx.one, ctx.owner, block(["gotcha: run mix format twice before pushing"]))
      say(ctx.two, ctx.owner, block(["gotcha: mix format needs two runs before you push"]))
      assert length(open(ctx.board)) == 2
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

      assert ctx.board |> open() |> Enum.map(& &1.count) == [1, 1, 1, 1]
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
