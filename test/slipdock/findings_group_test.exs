defmodule Slipdock.FindingsGroupTest do
  @moduledoc """
  The model grouping what the near match left (#2118, W-2310 §Findings,
  `Slipdock.Findings.Group`): one call for a finding that matched nothing,
  a yes merging it with the model's reason in its note, and a no, a bad
  answer, an error, AI off or no candidates changing nothing.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Boards, Findings, Repo}
  alias Slipdock.Findings.{Finding, Group}

  @kept "the CI cache can serve a stale `_build`, so a green run proves nothing"
  # Not alike in words (Lesson.alike?/2), but the same lesson.
  @reworded "CI passed on a build left over from an earlier run; clear the cache"

  setup do
    Slipdock.Config.override(:findings, async: false, group: true)
    owner = user_fixture()
    board = Boards.get_board!(board_fixture(%{"name" => "Grouped"}, owner: owner).id)
    [_backlog, doing | _] = board.columns
    one = card_fixture(doing, %{"title" => "One"})
    two = card_fixture(doing, %{"title" => "Two"})
    %{owner: owner, board: board, doing: doing, one: one, two: two}
  end

  defp say(card, owner, items) do
    body = "- Findings:\n" <> Enum.map_join(List.wrap(items), "\n", &"  - #{&1}")
    {:ok, comment} = Boards.Comments.add_comment(card, body, by: owner)
    comment
  end

  defp all(board),
    do: Repo.all(from(f in Finding, where: f.board_id == ^board.id, order_by: f.id))

  defp requests do
    receive do
      {:ai_request, body} -> [body | requests()]
    after
      0 -> []
    end
  end

  test "a yes merges it, with the model's reason in the note, after one call", ctx do
    refute Slipdock.Findings.Lesson.alike?(@kept, @reworded)
    say(ctx.one, ctx.owner, "tooling: #{@kept}")
    [kept] = all(ctx.board)

    AIStub.reply_with(%{"match" => kept.id, "reason" => "both say a cached build passed CI"})
    say(ctx.two, ctx.owner, "gotcha: #{@reworded}")

    assert [prompt] = requests()
    asked = Enum.map_join(prompt["messages"], "\n", & &1["content"])
    assert asked =~ "##{kept.id} (tooling): #{@kept}"
    assert asked =~ "The new note (gotcha): #{@reworded}"

    assert [%{id: id, status: "open", count: 2}, repeat] = all(ctx.board)
    assert id == kept.id
    assert %{status: "merged", merged_into_id: ^id, cause: "same-lesson-ai"} = repeat
    assert repeat.note == "same lesson as ##{id}, by the model: both say a cached build passed CI"

    # A person can reopen it, which takes its count back.
    assert {:ok, _} = Findings.triage(repeat, "reopen")
    assert %{count: 1} = Repo.get!(Finding, id)
    assert %{status: "open"} = Repo.get!(Finding, repeat.id)
  end

  test "a no leaves it alone; so does a match naming no candidate", ctx do
    say(ctx.one, ctx.owner, "tooling: #{@kept}")

    AIStub.reply_with(%{"match" => nil, "reason" => "different lessons"})
    say(ctx.two, ctx.owner, "gotcha: #{@reworded}")
    assert [_] = requests()

    three = card_fixture(ctx.doing, %{"title" => "Three"})
    AIStub.reply_with(%{"match" => 999_999, "reason" => "made up"})
    say(three, ctx.owner, "process: merges wait for an idle runner")
    assert [_] = requests()

    AIStub.reply_with("not json at all")

    say(
      card_fixture(ctx.doing, %{"title" => "Four"}),
      ctx.owner,
      "gotcha: the date picker drops the time zone"
    )

    assert [_] = requests()

    assert ctx.board |> all() |> Enum.map(& &1.status) == ~w(open open open open)
  end

  test "an error changes nothing", ctx do
    say(ctx.one, ctx.owner, "tooling: #{@kept}")
    AIStub.fail_with(503, "down")
    say(ctx.two, ctx.owner, "gotcha: #{@reworded}")

    assert [%{status: "open", count: 1}, %{status: "open", count: 1}] = all(ctx.board)
  end

  test "AI off: nothing is called", ctx do
    ai = Application.get_env(:slipdock, :ai, [])

    Slipdock.Config.override(
      :ai,
      Keyword.merge(ai, base_url: "https://openrouter.ai/api/v1", api_key: nil)
    )

    refute Slipdock.AI.configured?()
    say(ctx.one, ctx.owner, "tooling: #{@kept}")
    AIStub.reply_with(%{"match" => nil})
    say(ctx.two, ctx.owner, "gotcha: #{@reworded}")

    assert requests() == []
    assert [%{status: "open"}, %{status: "open"}] = all(ctx.board)
  end

  test "no call without candidates, nor for what the near match or the card already took",
       ctx do
    AIStub.reply_with(%{"match" => nil})

    # The first on the board has nothing to repeat.
    say(ctx.one, ctx.owner, "tooling: #{@kept}")
    # Merged by the near match, counted on its card, a rule, a settled item:
    # none is unmatched.
    say(ctx.two, ctx.owner, "tooling: #{@kept}")
    say(ctx.one, ctx.owner, "tooling: #{@kept}.")

    say(ctx.two, ctx.owner, [
      "rule: every MCP tool gets a docs test",
      "gotcha [done: W-3]: settled"
    ])

    assert requests() == []
    # Nor on one card alone: the same card's findings are not candidates.
    assert Group.candidates(hd(all(ctx.board))) == []
  end

  test "a runner's tooling is grouped only with the same runner's", ctx do
    say(ctx.one, ctx.owner, "tooling (runner): the installed CLI lags the repo")
    say(ctx.one, ctx.owner, "tooling: #{@kept}")
    [runner, board_scope] = all(ctx.board)

    assert Group.candidates(%{board_scope | id: -1, card_id: ctx.two.id}) |> Enum.map(& &1.id) ==
             [board_scope.id]

    assert Group.candidates(%{runner | id: -1, card_id: ctx.two.id}) |> Enum.map(& &1.id) == [
             runner.id
           ]
  end

  test "editing the comment takes the model's merge back", ctx do
    say(ctx.one, ctx.owner, "tooling: #{@kept}")
    [kept] = all(ctx.board)
    AIStub.reply_with(%{"match" => kept.id, "reason" => "same"})
    comment = say(ctx.two, ctx.owner, "gotcha: #{@reworded}")
    assert %{count: 2} = Repo.get!(Finding, kept.id)

    {:ok, _} = Boards.Comments.delete_comment(comment)
    assert [%{id: id, count: 1}] = all(ctx.board)
    assert id == kept.id
  end

  test "a settled item is the comment's own: parsing it again makes no second (#2120)", ctx do
    comment = say(ctx.one, ctx.owner, "gotcha [done: W-1950 §Local setup]: settled already")
    {:ok, _} = Findings.from_comment(comment)
    {:ok, _} = Findings.from_comment(comment)
    assert [%{status: "promoted", cause: "settled"}] = all(ctx.board)

    {:ok, _} = Boards.Comments.delete_comment(comment)
    assert all(ctx.board) == []
  end
end
