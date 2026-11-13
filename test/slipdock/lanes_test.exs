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
    {:ok, card} = Boards.Cards.update_card(card, %{"paths" => paths})
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

    test "plain names are compared whole, wildcards by character (#1977)" do
      assert Lanes.glob_overlap?("lib/a/b/c/d/e.ex", "lib/a/b/c/d/e.ex")
      refute Lanes.glob_overlap?("lib/a/b/c/d/e.ex", "lib/a/b/c/d/f.ex")
      refute Lanes.glob_overlap?("lib/a/b/c/d/e.ex", "test/a/b/c/d/e.ex")
      assert Lanes.glob_overlap?("lib/**/e.ex", "lib/a/b/c/d/e.ex")
      refute Lanes.glob_overlap?("lib/**/e.ex", "test/a/b/c/d/e.ex")
      assert Lanes.glob_overlap?("lib/a/*/c/[de].ex", "lib/a/b/c/x.ex")
      assert Lanes.glob_overlap?("lib/a/?/c.ex", "lib/a/b/c.ex")
      refute Lanes.glob_overlap?("lib/a/?/c.ex", "lib/a/bb/c.ex")
      # The same wildcard segment on both sides overlaps.
      assert Lanes.glob_overlap?("lib/*_test.exs", "lib/*_test.exs")
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

      {:ok, card} = Boards.Cards.update_card(card, %{paths: ["test/x.exs"]})
      assert card.paths == ["test/x.exs"]

      {:ok, card} = Boards.Cards.update_card(card, %{"paths" => []})
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
        assert {:error, changeset} = Boards.Cards.update_card(card, %{"paths" => paths})
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
      assert :ok = Boards.Cards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)
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
               Boards.Cards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)

      assert message =~ "##{running.id} \"Running\""
      assert message =~ "lib/runners/**"
      assert column_of(next) == ctx.todo.id
    end

    test "no overlap, no paths, or the other card done: it starts", ctx do
      _running = card(ctx.doing, "Running", "lib/runners/**")

      apart = card(ctx.todo, "Apart", "lib/boards/**")
      assert :ok = Boards.Cards.move_card(apart.id, ctx.doing.id, nil, actor: ctx.agent)

      unsaid = card_fixture(ctx.todo, %{"title" => "No paths"})
      assert :ok = Boards.Cards.move_card(unsaid.id, ctx.doing.id, nil, actor: ctx.agent)

      finished = card(ctx.doing, "Finished", "docs/**")
      {:ok, _} = Boards.Cards.update_card(finished, %{"completed" => true})
      docs = card(ctx.todo, "Docs", "docs/manual.md")
      assert :ok = Boards.Cards.move_card(docs.id, ctx.doing.id, nil, actor: ctx.agent)
    end

    test "moving to a list that isn't in progress is never refused", ctx do
      _running = card(ctx.doing, "Running", "lib/**")
      next = card(ctx.todo, "Next", "lib/a.ex")
      [backlog | _] = ctx.board.columns
      assert :ok = Boards.Cards.move_card(next.id, backlog.id, nil, actor: ctx.agent)
    end

    test "a person moving it is the override; an automation is never refused either", ctx do
      _running = card(ctx.doing, "Running", "lib/**")
      first = card(ctx.todo, "By hand", "lib/a.ex")

      assert :ok =
               Boards.Cards.move_card(first.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))

      assert column_of(first) == ctx.doing.id

      second = card(ctx.todo, "By rule", "lib/b.ex")
      assert :ok = Boards.Cards.move_card(second.id, ctx.doing.id, nil, actor: Actor.automation())
    end

    test "an agent can't widen an in-progress card's paths onto another's", ctx do
      running = card(ctx.doing, "Running", "lib/runners/**")
      working_job_fixture(running)
      mine = card(ctx.doing, "Mine", "lib/boards/**")

      assert {:error, changeset} =
               Boards.Cards.update_card(Repo.get!(Card, mine.id), %{"paths" => "lib/**"},
                 actor: ctx.agent
               )

      {message, _} = changeset.errors[:paths]
      assert message =~ ~r/##{running.id}\b/
      assert Repo.get!(Card, mine.id).paths == ["lib/boards/**"]

      # Narrowing is fine; so is a person widening it, and a card not started.
      assert {:ok, _} =
               Boards.Cards.update_card(Repo.get!(Card, mine.id), %{"paths" => "lib/boards/a.ex"},
                 actor: ctx.agent
               )

      assert {:ok, _} = Boards.Cards.update_card(Repo.get!(Card, mine.id), %{"paths" => "lib/**"})
      waiting = card(ctx.todo, "Waiting", "x/**")

      assert {:ok, _} =
               Boards.Cards.update_card(waiting, %{"paths" => "lib/**"}, actor: ctx.agent)
    end

    test "the card's own subcards and parents don't count against it", ctx do
      epic = card(ctx.doing, "Epic", "lib/**")
      # The epic's job works its subcards.
      working_job_fixture(epic)
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)
      assert sub.lanes, "a sub-board made afterwards inherits the switch"
      doing = doing_list(sub)
      todo = hd(sub.columns)

      child = card(todo, "Child", "lib/a.ex")
      assert :ok = Boards.Cards.move_card(child.id, doing.id, nil, actor: ctx.agent)

      # But a second child overlapping the first is refused, the first named.
      sibling = card(todo, "Sibling", "lib/a.ex")

      assert {:error, :unprocessable_entity, message} =
               Boards.Cards.move_card(sibling.id, doing.id, nil, actor: ctx.agent)

      assert message =~ ~r/##{child.id}\b/
    end

    test "the root's switch holds on a sub-board made before it was on", ctx do
      {:ok, off} = Boards.update_board(ctx.board, %{"lanes" => false})
      epic = card(ctx.todo, "Epic", [])
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
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
               Boards.Cards.move_card(child.id, doing.id, nil, actor: ctx.agent)

      assert message =~ ~r/##{running.id}\b/
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
      {:ok, _} = Boards.Cards.update_card(running, %{"completed" => true})
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
      card = card(ctx.todo, "Pathed", "lib/a/b/**\ntest/a_test.exs")
      {:ok, job} = queue(card)
      prompt = Runners.claimed_prompt(Repo.reload!(job))
      assert prompt =~ "The card's paths (its lane)"
      assert prompt =~ "lib/a/b/**\ntest/a_test.exs"

      plain = card_fixture(ctx.todo, %{"title" => "Unpathed"})
      {:ok, job} = queue(plain)

      assert Runners.claimed_prompt(Repo.reload!(job)) ==
               "go\n\n" <> Slipdock.Runners.ClaimMove.prompt_line(plain.id)
    end
  end

  describe "shared paths (#1971)" do
    defp share(board, globs) do
      {:ok, board} = Boards.update_board(board, %{"shared_paths" => globs})
      board
    end

    test "a glob is within another when everything it matches is" do
      assert Lanes.within?("docs/manual.md", "docs/manual.md")
      assert Lanes.within?("docs/manual.md", "docs/**")
      assert Lanes.within?("docs/a/b.md", "docs/*/b.md")
      assert Lanes.within?("docs/{manual,agents}.md", "docs/*.md")
      assert Lanes.within?("docs/a?.md", "docs/a*.md")
      assert Lanes.within?("README.md", "{README.md,docs/**}")

      # Wider than the shared glob, or only partly inside it: not within.
      refute Lanes.within?("docs/**", "docs/manual.md")
      refute Lanes.within?("docs/*.md", "docs/manual.md")
      refute Lanes.within?("docs/{manual,x}.md", "docs/manual.md")
      refute Lanes.within?("docs/a*.md", "docs/a?.md")
      refute Lanes.within?("lib/a.ex", "docs/**")
      # A class covers only the same class.
      assert Lanes.within?("docs/[ab].md", "docs/[ab].md")
      refute Lanes.within?("docs/x.md", "docs/[ab].md")
    end

    test "counted/2 drops the wholly shared globs and keeps the rest" do
      shared = ["docs/manual.md", "README.md"]

      assert Lanes.counted(["docs/manual.md", "lib/a.ex", "docs/**"], shared) == [
               "lib/a.ex",
               "docs/**"
             ]

      assert Lanes.counted(["lib/a.ex"], []) == ["lib/a.ex"]
    end

    test "the board takes them as a string or a list, tidied and checked like paths", ctx do
      board = share(ctx.board, "docs/manual.md, README.md\n./docs/agents.md")
      assert board.shared_paths == ["docs/manual.md", "README.md", "docs/agents.md"]
      assert share(board, "").shared_paths == []

      assert {:error, changeset} = Boards.update_board(board, %{"shared_paths" => ["/etc/x"]})
      assert %{shared_paths: [message]} = errors_on(changeset)
      assert message =~ "relative to the repository"

      assert {:error, changeset} = Boards.update_board(board, %{"shared_paths" => ["../x"]})
      assert errors_on(changeset).shared_paths != []
    end

    test "overlap only inside a shared path holds no lane; any other overlap still does", ctx do
      board = ctx |> on() |> share(["docs/manual.md", "README.md"])
      running = card(ctx.doing, "Running", "lib/a/**,docs/manual.md,README.md,docs/agents.md")
      working_job_fixture(running)

      docs_too = card(ctx.todo, "Docs too", "lib/b/**,docs/manual.md")
      assert Lanes.conflict(docs_too) == nil
      assert :ok = Boards.Cards.move_card(docs_too.id, ctx.doing.id, nil, actor: ctx.agent)

      code_too = card(ctx.todo, "Code too", "lib/a/x.ex,README.md")
      assert %Card{id: id} = Lanes.conflict(code_too)
      assert id == running.id

      # Partly inside a shared path counts in full: docs/** meets docs/agents.md.
      wide = card(ctx.todo, "Wide", "docs/**")
      assert %Card{id: ^id} = Lanes.conflict(wide)

      # Off again: the shared files hold as before.
      share(board, [])
      assert %Card{} = Lanes.conflict(card(ctx.todo, "Docs again", "docs/manual.md"))
    end

    test "a card in progress whose paths are all shared holds nothing", ctx do
      ctx |> on() |> share(["docs/**"])
      running = card(ctx.doing, "Docs only", "docs/manual.md")
      working_job_fixture(running)
      assert Lanes.conflict(card(ctx.todo, "Next", "docs/manual.md,lib/x.ex")) == nil
    end

    test "a queued job held only by a shared path isn't held", ctx do
      board = ctx |> on() |> share(["docs/manual.md"])
      {:ok, runner, _token} = Runners.create_runner(board, %{"name" => "r", "pool" => "dev"})
      running = card(ctx.doing, "Running", "lib/a/**,docs/manual.md")
      working_job_fixture(running)
      next = card(ctx.todo, "Next", "lib/b/**,docs/manual.md")
      held = card(ctx.todo, "Held", "lib/a/b.ex")
      {:ok, job} = Runners.queue(next, %{pool: "dev", kind: "claude", prompt: "go"})
      {:ok, held_job} = Runners.queue(held, %{pool: "dev", kind: "claude", prompt: "go"})

      assert Map.keys(Lanes.held_cards(board.id)) == [held.id]
      assert Runners.held_reason(Repo.reload!(job), claimant: true) == nil
      assert Runners.held_reason(Repo.reload!(held_job), claimant: true) =~ "Lane: overlaps"
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id
    end

    test "the claimed prompt names the card's shared paths", ctx do
      board = share(ctx.board, ["docs/**"])
      card = card(ctx.todo, "Pathed", "lib/a/b/**,docs/manual.md")
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
      prompt = Runners.claimed_prompt(Repo.reload!(job))
      assert prompt =~ "lib/a/b/**\ndocs/manual.md"
      assert prompt =~ "Shared on the board, so they hold no lane"
      # Then, last, the list the card is in (#2633).
      assert prompt =~
               ~r/rebase on the default branch before pushing:\ndocs\/manual.md\n\nThe card is in /

      share(board, [])

      {:ok, job} =
        Runners.queue(card(ctx.todo, "Plain", "docs/manual.md"), %{
          pool: "dev",
          kind: "claude",
          prompt: "go"
        })

      refute Runners.claimed_prompt(Repo.reload!(job)) =~ "Shared on the board"
    end

    test "the root's list holds for its tree, and sub-boards made afterwards inherit it", ctx do
      ctx |> on() |> share(["docs/manual.md"])
      epic = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      assert sub.shared_paths == ["docs/manual.md"]
      assert sub.lanes

      # The root's list counts even where the sub-board's own is cleared.
      {:ok, sub} = Boards.update_board(sub, %{"shared_paths" => []})
      assert Lanes.shared_paths(sub) == ["docs/manual.md"]
      {:ok, sub} = Boards.update_board(sub, %{"shared_paths" => ["README.md"]})
      assert Lanes.shared_paths(sub) == ["docs/manual.md", "README.md"]
    end
  end
end
