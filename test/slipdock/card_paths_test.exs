defmodule Slipdock.CardPathsTest do
  @moduledoc """
  Card paths once lanes went (#3178): they scope the handbook rules a card
  falls under and feed its inferred profile, and an overlap with another
  card in progress refuses, holds and advises nothing.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Handbook, Runners, Wiki}
  alias Slipdock.Boards.Card
  alias Slipdock.Handbook.Rules

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Paths", "code" => unique_code()}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    agent = Actor.runner(owner.id, nil, "bot")
    %{owner: owner, board: board, todo: todo, doing: doing, agent: agent}
  end

  defp card(column, title, paths) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.Cards.update_card(card, %{"paths" => paths})
    card
  end

  # A card in progress that a runner job is working on: what a lane held for.
  defp running(ctx, paths) do
    card = card(ctx.doing, "Running", paths)
    working_job_fixture(card)
    card
  end

  describe "paths scope the handbook rules" do
    setup ctx do
      {:ok, _} = Handbook.install(ctx.owner, ctx.board)
      data = Enum.find(Handbook.find(ctx.board).pages, &(&1.title == "Data model"))
      [_, key] = Regex.run(~r/^handbook:\s*(\S+)/m, data.front_matter)
      pre = Rules.prefix(key)
      front = String.replace(data.front_matter, ~r/^covers:.*$/m, "covers: [priv/repo/**]")
      [before, rest] = String.split(data.body, "## Rules", parts: 2)

      body =
        before <>
          "## Rules" <>
          String.trim_trailing(rest) <>
          "\n\n- **#{pre}-1** must · test/app/migrations_test.exs · Never edit a migration that has run.\n"

      {:ok, _} = Wiki.update_page(data, %{"front_matter" => front, "body" => body})
      %{rule: "#{pre}-1"}
    end

    test "a card's paths pick its rules, and overlapping cards each keep theirs", ctx do
      handbook = Handbook.find(ctx.board)
      ids = fn card -> Enum.map(Handbook.rules_for(handbook, card.paths), & &1.id) end

      migrating = running(ctx, "priv/repo/migrations/**")
      also = card(ctx.todo, "Also migrating", "priv/repo/migrations/2_x.exs")
      docs = card(ctx.todo, "Docs", "README.md")

      assert ctx.rule in ids.(migrating)
      assert ctx.rule in ids.(also)
      refute ctx.rule in ids.(docs)
      assert Handbook.rules_for(handbook, []) == []

      # The overlap is no reason to refuse the start any more.
      assert :ok = Boards.Cards.move_card(also.id, ctx.doing.id, nil, actor: ctx.agent)
      assert ctx.rule in ids.(Repo.get!(Card, also.id))
    end
  end

  describe "paths feed the profile" do
    test "an agent starting a card beside an overlapping one gets its profile from its paths",
         ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"profiles" => true})
      _running = running(ctx, "priv/repo/**")
      next = card(ctx.todo, "Migrate", "priv/repo/migrations/**")

      assert :ok = Boards.Cards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)
      assert %Card{profile: "schema"} = Repo.get!(Card, next.id)
    end
  end

  describe "an overlap holds nothing" do
    test "an agent creates, starts and widens overlapping cards in progress", ctx do
      _running = running(ctx, "lib/**")

      {:ok, made} =
        Boards.Cards.create_card(ctx.doing, %{"title" => "Made here", "paths" => "lib/a.ex"},
          actor: ctx.agent
        )

      assert made.column_id == ctx.doing.id

      next = card(ctx.todo, "Next", "docs/a.md")
      assert :ok = Boards.Cards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)

      assert {:ok, %Card{paths: ["lib/b.ex"]}} =
               Boards.Cards.update_card(Repo.get!(Card, next.id), %{"paths" => "lib/b.ex"},
                 actor: ctx.agent
               )
    end

    test "an overlapping card's queued job is neither held nor told about the other", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})
      _running = running(ctx, "lib/**")
      waiting = card(ctx.todo, "Waiting", "lib/a.ex")
      {:ok, job} = Runners.queue(waiting, %{pool: "dev", kind: "claude", prompt: "go"})

      assert Runners.held_reason(Repo.reload!(job), claimant: true) == nil
      # The only thing held against it is the runner not seen yet: no lane.
      refute Runners.held_reasons([Repo.reload!(job)])[job.id] =~ "Lane"
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id

      prompt = Runners.claimed_prompt(Repo.reload!(job))
      assert prompt =~ "The card's paths (what its handbook rules and profile go by)"
      assert prompt =~ "lib/a.ex"
      refute prompt =~ ~r/lane/i
    end

    test "the board's old lane settings are ignored", ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{
          "lanes" => true,
          "lane_mode" => "hold",
          "shared_paths" => "docs/manual.md"
        })

      refute Map.has_key?(Map.from_struct(board), :lane_mode)
      _running = running(ctx, "lib/**")
      next = card(ctx.todo, "Next", "lib/a.ex")
      assert :ok = Boards.Cards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)
    end
  end
end
