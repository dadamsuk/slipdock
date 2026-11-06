defmodule Slipdock.EpicLogTest do
  @moduledoc """
  Epic comments (#1881): the server posts each subcard's progress on its
  epic, one terse line per event with the epic's done count; lines close
  together share a comment; the epic's own verification posts the same
  lines; and the epic's % complete follows its subcards unless a person set
  it by hand.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Deployments, EpicLog, Repo, Verified}
  alias Slipdock.Boards.{Card, Comment}

  @pr "https://github.com/acme/app/pull/7"
  @sha "abc1234def5678abc1234def5678abc1234def56"

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Epics", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

    [_backlog, _todo, doing, _done] = board.columns
    epic = card_fixture(doing, %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    columns = Boards.get_board!(sub.id).columns
    ready = Enum.find(columns, &(&1.category == "todo")) || hd(columns)
    working = Enum.find(columns, &(&1.name == "Doing"))

    builder = %{
      Actor.unknown()
      | kind: "agent",
        via: "cli",
        user_id: owner.id,
        agent: "builder",
        job_id: 641
    }

    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    one = card_fixture(ready, %{"title" => "First part"})
    two = card_fixture(ready, %{"title" => "Second part"})

    %{
      owner: owner,
      board: board,
      epic: epic,
      sub: sub,
      ready: ready,
      working: working,
      one: one,
      two: two,
      builder: builder,
      checker: checker
    }
  end

  defp lines(card) do
    from(c in Comment,
      where: c.card_id == ^card.id and c.kind == ^EpicLog.kind(),
      order_by: c.id,
      select: c.body
    )
    |> Repo.all()
  end

  defp fresh(card), do: Repo.get!(Card, card.id)

  # Moves the epic's lines back in time, so the next starts a comment of
  # its own (or, for a merge, falls outside the acceptance's minute).
  defp age(card, seconds) do
    at = DateTime.add(DateTime.utc_now(:second), -seconds, :second)

    from(c in Comment, where: c.card_id == ^card.id)
    |> Repo.update_all(set: [updated_at: at, inserted_at: at])
  end

  defp start(card, ctx), do: Boards.move_card(card.id, ctx.working.id, nil, actor: ctx.builder)

  defp submit(card, ctx, pr \\ @pr) do
    {:ok, card} =
      Boards.update_card(
        fresh(card),
        %{"completed" => true, "evidence_pr" => pr, "evidence_commit" => "abc1234"},
        actor: ctx.builder
      )

    assert card.verify_state == "pending"
    card
  end

  defp accept(card, ctx),
    do: Verified.decide(fresh(card), "accept", %{}, ctx.checker, ctx.owner)

  defp merged(card, ctx),
    do:
      Verified.decide(fresh(card), "merged", %{"commit" => @sha}, Actor.web(ctx.owner), ctx.owner)

  describe "a subcard's events, one line each on the epic" do
    test "started: who and which job, and the done count", ctx do
      :ok = start(ctx.one, ctx)

      assert [line] = lines(ctx.epic)
      assert line =~ "**Started** · ##{ctx.one.id} First part"
      assert line =~ "by agent “builder”, job #641"
      assert line =~ "0/2 done"
    end

    test "submitted, with its pull request and commit", ctx do
      submit(ctx.one, ctx)

      assert [line] = lines(ctx.epic)
      assert line =~ "**Submitted** for verification · ##{ctx.one.id} First part"
      assert line =~ "[PR #7](#{@pr})"
      assert line =~ "`abc1234`"
      assert line =~ "0/2 done"
    end

    test "rejected: the first line of the reason only", ctx do
      submit(ctx.one, ctx)
      age(ctx.epic, 30)

      {:ok, _} =
        Verified.decide(
          fresh(ctx.one),
          "reject",
          %{"reason" => "bar 2: no test for the empty case\n\nMore detail here."},
          ctx.checker,
          ctx.owner
        )

      line = List.last(lines(ctx.epic))

      assert line =~
               "**Rejected** · ##{ctx.one.id} First part · bar 2: no test for the empty case"

      refute line =~ "More detail"
    end

    test "accepted and merged within a minute is one line, with the merge commit", ctx do
      submit(ctx.one, ctx)
      age(ctx.epic, 30)
      {:ok, _} = accept(ctx.one, ctx)
      [_, accepted] = lines(ctx.epic)
      assert accepted =~ "**Accepted** · ##{ctx.one.id} First part · [PR #7](#{@pr}) · `abc1234`"

      {:ok, _} = merged(ctx.one, ctx)

      assert [_, line] = lines(ctx.epic)
      assert line =~ "**Accepted and merged** · ##{ctx.one.id} First part"
      assert line =~ "`abc1234`"
      refute line =~ "**Accepted** ·"
      assert line =~ "1/2 done"
    end

    test "a merge more than a minute after the acceptance is a line of its own", ctx do
      submit(ctx.one, ctx)
      {:ok, _} = accept(ctx.one, ctx)
      age(ctx.epic, 90)
      {:ok, _} = merged(ctx.one, ctx)

      all = Enum.join(lines(ctx.epic), "\n\n")
      assert all =~ "**Accepted** · ##{ctx.one.id}"
      assert List.last(lines(ctx.epic)) =~ "**Merged** · ##{ctx.one.id} First part · [PR #7]"
      assert List.last(lines(ctx.epic)) =~ "`abc1234` · 1/2 done"
    end

    test "a build reported red on the subcard", ctx do
      {:ok, _} =
        Boards.add_comment(
          ctx.one,
          "Build failed: CI #4321 — job test, step mix test\n\nthe log lines",
          by: ctx.owner
        )

      assert [line] = lines(ctx.epic)
      assert line =~ "**Build failed** · ##{ctx.one.id} First part · CI #4321 — job test"
      refute line =~ "the log lines"
      # The epic's own lines are never read as a report.
      assert length(Repo.all(from c in Comment, where: c.card_id == ^ctx.epic.id)) == 1
    end

    test "an ordinary comment posts nothing", ctx do
      {:ok, _} = Boards.add_comment(ctx.one, "The build failed once, then passed", by: ctx.owner)
      assert lines(ctx.epic) == []
    end

    test "a wait opened and answered", ctx do
      {:ok, _wait} =
        Boards.open_wait(ctx.one, ctx.builder, %{"needs" => "Which colour?\nDetails below"})

      assert [opened] = lines(ctx.epic)
      assert opened =~ "**Waiting on a person** · ##{ctx.one.id} First part · Which colour?"
      refute opened =~ "Details below"

      age(ctx.epic, 30)
      {:ok, _} = Boards.answer_wait(fresh(ctx.one), Actor.web(ctx.owner), %{"answer" => "Blue"})
      assert List.last(lines(ctx.epic)) =~ "**Answered** · ##{ctx.one.id} First part"
    end

    test "shipped, once per epic for the cards a deploy names", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"delivery_metrics" => true})

      {:ok, deploy} =
        Deployments.start(board, %{
          "environment" => "production",
          "sha" => @sha,
          "commits" => [
            %{"sha" => @sha, "message" => "Part one (##{ctx.one.id}) and two (##{ctx.two.id})"}
          ]
        })

      assert lines(ctx.epic) == []
      {:ok, _} = Deployments.finish(board, deploy.id, "succeeded")

      assert [line] = lines(ctx.epic)
      assert line =~ "**Shipped** to production · ##{ctx.one.id}, ##{ctx.two.id} · `abc1234`"
    end

    test "a failed deploy posts nothing", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"delivery_metrics" => true})

      {:ok, deploy} =
        Deployments.start(board, %{
          "environment" => "production",
          "sha" => @sha,
          "commits" => [%{"sha" => @sha, "message" => "Part one (##{ctx.one.id})"}]
        })

      {:ok, _} = Deployments.finish(board, deploy.id, "failed")
      assert lines(ctx.epic) == []
    end

    test "done, on a board that doesn't verify", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"verify_work" => false})
      {:ok, _} = Boards.update_board(ctx.sub, %{"verify_work" => false})
      {:ok, _} = Boards.update_card(fresh(ctx.one), %{"completed" => true}, actor: ctx.builder)

      assert [line] = lines(ctx.epic)
      assert line =~ "**Done** · ##{ctx.one.id} First part · 1/2 done"
    end
  end

  describe "where lines go" do
    test "a sub-subcard posts on the top-level epic, not its parent", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, subsub} = sub_board(ctx.one, t)
      columns = Boards.get_board!(subsub.id).columns
      deep = card_fixture(hd(columns), %{"title" => "Deep"})
      deep_doing = Enum.find(columns, &(&1.name == "Doing"))

      :ok = Boards.move_card(deep.id, deep_doing.id, nil, actor: ctx.builder)

      assert [line] = lines(ctx.epic)
      assert line =~ "**Started** · ##{deep.id} Deep"
      assert lines(ctx.one) == []
    end

    test "a card under no epic posts nothing anywhere", ctx do
      [_backlog, todo, doing, _done] = ctx.board.columns
      plain = card_fixture(todo, %{"title" => "Plain"})

      :ok = Boards.move_card(plain.id, doing.id, nil, actor: ctx.builder)
      submit(plain, ctx)

      assert Repo.all(from c in Comment, where: c.kind == ^EpicLog.kind()) == []
    end

    test "the epic's own submit, accept and merge post on the epic", ctx do
      for card <- [ctx.one, ctx.two] do
        submit(card, ctx)
        {:ok, _} = accept(card, ctx)
        {:ok, _} = merged(card, ctx)
      end

      # A pull request of the epic's own, which the acceptance merges (#1917).
      own = "https://github.com/acme/app/pull/8"
      age(ctx.epic, 120)
      submit(ctx.epic, ctx, own)
      assert List.last(lines(ctx.epic)) =~ "**Submitted** for verification · the epic itself"
      assert List.last(lines(ctx.epic)) =~ "[PR #8](#{own}) · `abc1234` · 2/2 done"

      age(ctx.epic, 120)
      {:ok, _} = accept(ctx.epic, ctx)
      assert List.last(lines(ctx.epic)) =~ "**Accepted** · the epic itself · [PR #8]"

      {:ok, _} = merged(ctx.epic, ctx)
      assert List.last(lines(ctx.epic)) =~ "**Accepted and merged** · the epic itself"
      assert List.last(lines(ctx.epic)) =~ "`abc1234` · 2/2 done"
    end

    test "an epic naming a PR its subcards merged is accepted with nothing to merge (#1917)",
         ctx do
      for card <- [ctx.one, ctx.two] do
        submit(card, ctx)
        {:ok, _} = accept(card, ctx)
        {:ok, _} = merged(card, ctx)
      end

      age(ctx.epic, 120)
      submit(ctx.epic, ctx)
      age(ctx.epic, 120)
      assert {:ok, %{completed: true, verify_state: "accepted"}} = accept(ctx.epic, ctx)
      assert List.last(lines(ctx.epic)) =~ "**Accepted** · the epic itself"
    end

    test "the epic's own start posts nothing", ctx do
      [_backlog, todo, doing, _done] = ctx.board.columns
      :ok = Boards.move_card(ctx.epic.id, todo.id, nil, actor: ctx.builder)
      :ok = Boards.move_card(ctx.epic.id, doing.id, nil, actor: ctx.builder)
      assert lines(ctx.epic) == []
    end
  end

  describe "volume" do
    test "lines a few seconds apart share one comment", ctx do
      :ok = start(ctx.one, ctx)
      :ok = start(ctx.two, ctx)

      assert [comment] = lines(ctx.epic)
      assert [first, second] = String.split(comment, "\n\n")
      assert first =~ "##{ctx.one.id}"
      assert second =~ "##{ctx.two.id}"
    end

    test "lines further apart than the window are comments of their own", ctx do
      :ok = start(ctx.one, ctx)
      age(ctx.epic, EpicLog.join_seconds() + 5)
      :ok = start(ctx.two, ctx)

      assert [_, _] = lines(ctx.epic)
    end

    test "a person's comment in between starts a new one", ctx do
      :ok = start(ctx.one, ctx)
      {:ok, _} = Boards.add_comment(ctx.epic, "Looking good", by: ctx.owner)
      :ok = start(ctx.two, ctx)

      assert [_, _] = lines(ctx.epic)
    end
  end

  test "the agents' guide leaves the epic's record to the server", ctx do
    guide =
      ctx.owner |> then(&SlipdockWeb.APIGuide.markdown(user: &1)) |> String.replace(~r/\s+/, " ")

    assert guide =~ "**The server keeps an epic's record.**"
    assert guide =~ "comment on the epic what only you know, your decisions, surprises, dead ends"
    refute SlipdockWeb.APIGuide.short(user: ctx.owner) =~ "keeps an epic's record"
  end

  describe "the epic's % complete" do
    test "follows done ÷ all on each change, past an agent's own setting", ctx do
      {:ok, _} =
        Boards.update_card(fresh(ctx.epic), %{"percent_complete" => 0}, actor: ctx.builder)

      refute fresh(ctx.epic).percent_by_hand

      submit(ctx.one, ctx)
      {:ok, _} = accept(ctx.one, ctx)
      {:ok, _} = merged(ctx.one, ctx)
      assert fresh(ctx.epic).percent_complete == 50

      three = card_fixture(ctx.ready, %{"title" => "Third"})
      assert fresh(ctx.epic).percent_complete == 33

      {:ok, _} = Boards.archive_card(three)
      assert fresh(ctx.epic).percent_complete == 50
    end

    test "stays as a person set it by hand, and follows again once they clear it", ctx do
      {:ok, _} =
        Boards.update_card(fresh(ctx.epic), %{"percent_complete" => 80},
          actor: Actor.web(ctx.owner),
          by: ctx.owner
        )

      assert fresh(ctx.epic).percent_by_hand

      submit(ctx.one, ctx)
      {:ok, _} = accept(ctx.one, ctx)
      {:ok, _} = merged(ctx.one, ctx)
      assert fresh(ctx.epic).percent_complete == 80

      {:ok, _} =
        Boards.update_card(fresh(ctx.epic), %{"percent_complete" => nil},
          actor: Actor.web(ctx.owner),
          by: ctx.owner
        )

      refute fresh(ctx.epic).percent_by_hand
      :ok = start(ctx.two, ctx)
      assert fresh(ctx.epic).percent_complete == 50
    end
  end
end
