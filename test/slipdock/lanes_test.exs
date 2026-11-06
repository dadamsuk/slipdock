defmodule Slipdock.LanesTest do
  @moduledoc """
  Lanes 2 (#1628): a card's paths, and a board that refuses an agent
  starting a card whose paths overlap one in progress — naming it — while
  people, automations and boards with the switch off are never refused.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Lanes, Runners}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Lanes"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    agent = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "bot"}
    %{owner: owner, board: board, todo: todo, doing: doing, agent: agent}
  end

  defp on(ctx) do
    {:ok, board} = Boards.update_board(ctx.board, %{"lanes" => true})
    board
  end

  defp card(column, title, paths) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.update_card(card, %{"paths" => paths})
    card
  end

  # The Simple template's "Doing", made an in-progress list.
  defp doing_list(sub) do
    sub.columns
    |> Enum.find(&(&1.name == "Doing"))
    |> Ecto.Changeset.change(category: "doing")
    |> Repo.update!()
  end

  defp column_of(card), do: Repo.get!(Card, card.id).column_id

  describe "glob overlap" do
    test "the same path, or one under the other, overlaps" do
      assert Lanes.glob_overlap?("lib/a.ex", "lib/a.ex")
      assert Lanes.glob_overlap?("lib/foo", "lib/foo/bar.ex")
      assert Lanes.glob_overlap?("lib/foo/", "lib/foo/bar/baz.ex")
      assert Lanes.glob_overlap?("lib/foo/bar.ex", "lib")
      refute Lanes.glob_overlap?("lib/foo", "lib/foobar")
      refute Lanes.glob_overlap?("lib/a.ex", "lib/b.ex")
      refute Lanes.glob_overlap?("lib/a.ex", "test/a.ex")
    end

    test "** is any number of segments, * and ? stay in one" do
      assert Lanes.glob_overlap?("lib/**", "lib/a/b/c.ex")
      assert Lanes.glob_overlap?("**/*_test.exs", "test/slipdock/lanes_test.exs")
      assert Lanes.glob_overlap?("lib/**/runner.ex", "lib/slipdock/runners/runner.ex")
      assert Lanes.glob_overlap?("lib/*.ex", "lib/lanes.ex")
      refute Lanes.glob_overlap?("lib/*.ex", "test/lanes.ex")
      refute Lanes.glob_overlap?("lib/*.ex", "lib/lanes.exs")
      assert Lanes.glob_overlap?("lib/?.ex", "lib/a.ex")
      refute Lanes.glob_overlap?("lib/?.ex", "lib/ab.ex")
      # A * never crosses a /, but the file's own directory is under it.
      assert Lanes.glob_overlap?("lib/*", "lib/a/b.ex")
    end

    test "two wildcards overlap when some name matches both" do
      assert Lanes.glob_overlap?("lib/*_live.ex", "lib/board_*")
      refute Lanes.glob_overlap?("lib/*.ex", "lib/*.md")
      assert Lanes.glob_overlap?("**", "anything/at/all")
      assert Lanes.glob_overlap?("a/**/z", "a/b/**")
    end

    test "{a,b} is either, and [..] is taken as any one character" do
      assert Lanes.glob_overlap?("docs/{manual,agents}.md", "docs/agents.md")
      refute Lanes.glob_overlap?("docs/{manual,agents}.md", "docs/readme.md")
      assert Lanes.glob_overlap?("lib/{a,b/{c,d}}.ex", "lib/b/d.ex")
      assert Lanes.glob_overlap?("lib/[ab].ex", "lib/c.ex")
    end

    test "lists overlap when any pair does; an empty list overlaps nothing" do
      assert Lanes.overlap?(["lib/a/**", "docs/x.md"], ["test/**", "docs/*.md"])
      refute Lanes.overlap?(["lib/a/**"], ["lib/b/**", "test/**"])
      refute Lanes.overlap?([], ["**"])
    end
  end

  describe "writing paths" do
    test "a list or a string, tidied", ctx do
      card = card(ctx.todo, "Tidy", " ./lib/a/** ,\ndocs/{manual,agents}.md\n\nlib/a/** ")
      assert card.paths == ["lib/a/**", "docs/{manual,agents}.md"]

      {:ok, card} = Boards.update_card(card, %{paths: ["test/x.exs"]})
      assert card.paths == ["test/x.exs"]

      {:ok, card} = Boards.update_card(card, %{"paths" => []})
      assert card.paths == []
    end

    test "absolute paths, .., unbalanced braces and too many are refused", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Bad"})

      for {paths, words} <- [
            {"/etc/passwd", "relative"},
            {"C:/x", "relative"},
            {"~/x", "relative"},
            {"lib/../secret", ".."},
            {"lib/{a,b.ex", "braces"},
            {Enum.map(1..51, &"p#{&1}"), "at most 50"},
            {[String.duplicate("a", 201)], "over 200"}
          ] do
        assert {:error, changeset} = Boards.update_card(card, %{"paths" => paths})
        {message, _} = changeset.errors[:paths]
        assert message =~ words, inspect(paths)
      end
    end
  end

  describe "with the switch off (the default)" do
    test "paths are kept, and an agent starts an overlapping card", ctx do
      refute ctx.board.lanes
      _running = card(ctx.doing, "Running", "lib/**")
      next = card(ctx.todo, "Next", "lib/a.ex")
      assert :ok = Boards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)
      assert column_of(next) == ctx.doing.id
      assert Lanes.conflict(next) == nil
    end
  end

  describe "with the switch on" do
    setup ctx, do: %{board: on(ctx)}

    test "an agent can't start an overlapping card, and is told which card is in the way", ctx do
      running = card(ctx.doing, "Running", "lib/runners/**")
      working_job_fixture(running)
      next = card(ctx.todo, "Next", "lib/runners/claim.ex")

      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)

      assert message =~ "##{running.id} \"Running\""
      assert message =~ "lib/runners/**"
      assert column_of(next) == ctx.todo.id
    end

    test "no overlap, no paths, or the other card done: it starts", ctx do
      _running = card(ctx.doing, "Running", "lib/runners/**")

      apart = card(ctx.todo, "Apart", "lib/boards/**")
      assert :ok = Boards.move_card(apart.id, ctx.doing.id, nil, actor: ctx.agent)

      unsaid = card_fixture(ctx.todo, %{"title" => "No paths"})
      assert :ok = Boards.move_card(unsaid.id, ctx.doing.id, nil, actor: ctx.agent)

      finished = card(ctx.doing, "Finished", "docs/**")
      {:ok, _} = Boards.update_card(finished, %{"completed" => true})
      docs = card(ctx.todo, "Docs", "docs/manual.md")
      assert :ok = Boards.move_card(docs.id, ctx.doing.id, nil, actor: ctx.agent)
    end

    test "moving to a list that isn't in progress is never refused", ctx do
      _running = card(ctx.doing, "Running", "lib/**")
      next = card(ctx.todo, "Next", "lib/a.ex")
      [backlog | _] = ctx.board.columns
      assert :ok = Boards.move_card(next.id, backlog.id, nil, actor: ctx.agent)
    end

    test "a person moving it is the override; an automation is never refused either", ctx do
      _running = card(ctx.doing, "Running", "lib/**")
      first = card(ctx.todo, "By hand", "lib/a.ex")
      assert :ok = Boards.move_card(first.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      assert column_of(first) == ctx.doing.id

      second = card(ctx.todo, "By rule", "lib/b.ex")
      assert :ok = Boards.move_card(second.id, ctx.doing.id, nil, actor: Actor.automation())
    end

    test "an agent can't widen an in-progress card's paths onto another's", ctx do
      running = card(ctx.doing, "Running", "lib/runners/**")
      working_job_fixture(running)
      mine = card(ctx.doing, "Mine", "lib/boards/**")

      assert {:error, changeset} =
               Boards.update_card(Repo.get!(Card, mine.id), %{"paths" => "lib/**"},
                 actor: ctx.agent
               )

      {message, _} = changeset.errors[:paths]
      assert message =~ "##{running.id}"
      assert Repo.get!(Card, mine.id).paths == ["lib/boards/**"]

      # Narrowing is fine; so is a person widening it, and a card not started.
      assert {:ok, _} =
               Boards.update_card(Repo.get!(Card, mine.id), %{"paths" => "lib/boards/a.ex"},
                 actor: ctx.agent
               )

      assert {:ok, _} = Boards.update_card(Repo.get!(Card, mine.id), %{"paths" => "lib/**"})
      waiting = card(ctx.todo, "Waiting", "x/**")
      assert {:ok, _} = Boards.update_card(waiting, %{"paths" => "lib/**"}, actor: ctx.agent)
    end

    test "the card's own subcards and parents don't count against it", ctx do
      epic = card(ctx.doing, "Epic", "lib/**")
      # The epic's job works its subcards.
      working_job_fixture(epic)
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      assert sub.lanes, "a sub-board made afterwards inherits the switch"
      doing = doing_list(sub)
      todo = hd(sub.columns)

      child = card(todo, "Child", "lib/a.ex")
      assert :ok = Boards.move_card(child.id, doing.id, nil, actor: ctx.agent)

      # But a second child overlapping the first is refused, the first named.
      sibling = card(todo, "Sibling", "lib/a.ex")

      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(sibling.id, doing.id, nil, actor: ctx.agent)

      assert message =~ "##{child.id}"
    end

    test "the root's switch holds on a sub-board made before it was on", ctx do
      {:ok, off} = Boards.update_board(ctx.board, %{"lanes" => false})
      epic = card(ctx.todo, "Epic", [])
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      refute sub.lanes
      on(%{ctx | board: off})

      running = card(ctx.doing, "Running", "lib/**")
      working_job_fixture(running)
      todo = hd(sub.columns)
      doing = doing_list(sub)
      child = card(todo, "Child", "lib/a.ex")

      assert {:error, :unprocessable_entity, message} =
               Boards.move_card(child.id, doing.id, nil, actor: ctx.agent)

      assert message =~ "##{running.id}"
    end
  end

  describe "runner jobs" do
    setup ctx do
      board = on(ctx)
      {:ok, runner, _token} = Runners.create_runner(board, %{"name" => "r", "pool" => "dev"})
      %{board: board, runner: runner}
    end

    defp queue(card), do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

    test "an overlapping card's job is held, said why, and the next one is claimed", ctx do
      running = card(ctx.doing, "Running", "lib/**")
      working_job_fixture(running)
      blocked = card(ctx.todo, "Blocked", "lib/a.ex")
      free = card(ctx.todo, "Free", "docs/**")
      {:ok, held} = queue(blocked)
      {:ok, next} = queue(free)

      assert Runners.held_reason(Repo.reload!(held), claimant: true) ==
               "Lane: overlaps ##{running.id}, in progress"

      assert Runners.held_reasons([Repo.reload!(held)])[held.id] ==
               "Lane: overlaps ##{running.id}, in progress"

      assert %{id: id} = Runners.claim(ctx.runner)
      assert id == next.id
      assert Runners.claim(ctx.runner) == nil

      # The card in the way finishes: the held job goes.
      {:ok, _} = Boards.update_card(running, %{"completed" => true})
      assert %{id: id} = Runners.claim(ctx.runner)
      assert id == held.id
    end

    test "a job whose card is already in progress (a person moved it) is not held", ctx do
      _running = card(ctx.doing, "Running", "lib/**")
      moved = card(ctx.doing, "Moved by hand", "lib/a.ex")
      {:ok, job} = queue(moved)
      assert Runners.held_reason(Repo.reload!(job), claimant: true) == nil
      assert %{id: id} = Runners.claim(ctx.runner)
      assert id == job.id
    end

    test "the claimed prompt carries the card's paths", ctx do
      card = card(ctx.todo, "Pathed", "lib/a/**\ntest/a_test.exs")
      {:ok, job} = queue(card)
      prompt = Runners.claimed_prompt(Repo.reload!(job))
      assert prompt =~ "The card's paths (its lane)"
      assert prompt =~ "lib/a/**\ntest/a_test.exs"

      plain = card_fixture(ctx.todo, %{"title" => "Unpathed"})
      {:ok, job} = queue(plain)
      assert Runners.claimed_prompt(Repo.reload!(job)) == "go"
    end
  end
end
