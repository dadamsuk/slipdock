defmodule Slipdock.LanesAdviseTest do
  @moduledoc """
  Advisory lanes (#1972): a board's lane mode, `off`, `hold` or `advise`.
  `lanes: true/false` still means `hold`/`off`; under `advise` no start is
  refused and no job held, and a claimed job's prompt names each overlapping
  card in progress instead, with nothing said when none overlaps.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Lanes, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Health.{Context, Detectors.LaneHog}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Advise"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    agent = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "bot"}
    %{owner: owner, board: board, todo: todo, doing: doing, agent: agent}
  end

  defp mode(board, mode) do
    {:ok, board} = Boards.update_board(board, %{"lane_mode" => mode})
    board
  end

  defp card(column, title, paths) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.update_card(card, %{"paths" => paths})
    card
  end

  defp queue(card), do: Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

  describe "the mode" do
    test "off by default; lane_mode sets it and the switch follows", ctx do
      assert ctx.board.lane_mode == "off"
      assert Lanes.mode(ctx.board) == "off"

      board = mode(ctx.board, "advise")
      assert {board.lane_mode, board.lanes} == {"advise", true}
      assert Lanes.mode(board) == "advise"

      board = mode(board, "off")
      assert {board.lane_mode, board.lanes} == {"off", false}
    end

    test "lanes: true/false still means hold/off; a lane_mode in the same write wins", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"lanes" => true})
      assert {board.lane_mode, board.lanes} == {"hold", true}

      {:ok, board} = Boards.update_board(mode(board, "advise"), %{"lanes" => false})
      assert {board.lane_mode, board.lanes} == {"off", false}

      {:ok, board} = Boards.update_board(board, %{"lanes" => false, "lane_mode" => "advise"})
      assert {board.lane_mode, board.lanes} == {"advise", true}

      assert {:error, changeset} = Boards.update_board(board, %{"lane_mode" => "sometimes"})
      assert %{lane_mode: [message]} = errors_on(changeset)
      assert message =~ "off, hold, advise"
    end

    test "sub-boards made afterwards inherit it, and the root's mode holds for its tree", ctx do
      board = mode(ctx.board, "advise")
      epic = card_fixture(ctx.todo, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      assert {sub.lane_mode, sub.lanes} == {"advise", true}

      {:ok, sub} = Boards.update_board(sub, %{"lane_mode" => "hold"})
      assert Lanes.mode(sub) == "advise"

      mode(board, "off")
      assert Lanes.mode(Boards.get_board!(sub.id)) == "hold"
    end
  end

  describe "under advise" do
    setup ctx do
      board = mode(ctx.board, "advise")
      running = card(ctx.doing, "Running", "lib/runners/**,docs/manual.md")
      working_job_fixture(running, %{runner_name: "mac-studio"})
      %{board: board, running: running}
    end

    test "an agent's overlapping start goes ahead; the overlap is still seen", ctx do
      next = card(ctx.todo, "Next", "lib/runners/claim.ex")
      assert %Card{id: id} = Lanes.conflict(next)
      assert id == ctx.running.id
      assert :ok = Boards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)
      assert Repo.get!(Card, next.id).column_id == ctx.doing.id

      # Widening an in-progress card's paths onto another's isn't refused either.
      assert {:ok, _} =
               Boards.update_card(Repo.get!(Card, next.id), %{"paths" => "lib/**"},
                 actor: ctx.agent
               )
    end

    test "creating a card straight into progress with overlapping paths goes ahead", ctx do
      assert {:ok, _card} =
               Boards.create_card(
                 ctx.doing,
                 %{"title" => "Straight in", "paths" => ["lib/runners/a.ex"]},
                 actor: ctx.agent
               )
    end

    test "no job is held, so the overlapping card's job is claimed", ctx do
      next = card(ctx.todo, "Next", "lib/runners/claim.ex")
      {:ok, runner, _token} = Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})
      {:ok, job} = queue(next)

      assert Lanes.held_cards(ctx.board.id) == %{}
      assert Runners.held_reason(Repo.reload!(job), claimant: true) == nil
      assert %{id: id} = Runners.claim(runner)
      assert id == job.id
    end

    test "the claimed prompt carries a Lanes block naming the card, globs, job and runner",
         ctx do
      next = card(ctx.todo, "Next", "lib/runners/claim.ex,lib/boards/**")
      {:ok, job} = queue(next)
      prompt = Runners.claimed_prompt(Repo.reload!(job))

      [running_job] =
        Repo.all(from(j in Slipdock.Runners.Job, where: j.card_id == ^ctx.running.id))

      assert prompt =~ "Lanes (advisory): this board doesn't hold overlapping work"

      assert prompt =~
               ~s[- ##{ctx.running.id} "Running" (job ##{running_job.id} on mac-studio): your lib/runners/claim.ex meets its lib/runners/**]

      refute prompt =~ "lib/boards/** meets"
      assert prompt =~ "read that card (slipdock card <id>)"
      assert prompt =~ "rebase on the default branch before pushing"
    end

    test "no overlap, or an overlap only in a shared path: no Lanes block", ctx do
      {:ok, job} = queue(card(ctx.todo, "Apart", "lib/boards/**"))
      refute Runners.claimed_prompt(Repo.reload!(job)) =~ "Lanes (advisory)"

      mode(ctx.board, "advise") |> Boards.update_board(%{"shared_paths" => ["docs/manual.md"]})
      {:ok, job} = queue(card(ctx.todo, "Docs", "docs/manual.md"))
      refute Runners.claimed_prompt(Repo.reload!(job)) =~ "Lanes (advisory)"
    end

    test "every overlapping card is named, an epic's job standing for its subcard's", ctx do
      epic = card(ctx.doing, "Epic", "")
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      doing = Boards.get_board!(sub.id).columns |> Enum.find(&(&1.name == "Doing"))
      doing = doing |> Ecto.Changeset.change(category: "doing") |> Repo.update!()
      inner = card(doing, "Inner", "docs/manual.md")
      epic_job = working_job_fixture(epic, %{runner_name: "linux-box"})

      next = card(ctx.todo, "Next", "lib/runners/a.ex,docs/**")
      overlaps = Lanes.overlaps(next)

      assert Enum.map(overlaps, & &1.card.id) |> Enum.sort() ==
               Enum.sort([ctx.running.id, inner.id])

      assert Lanes.working_job(inner).id == epic_job.id

      {:ok, job} = queue(next)
      prompt = Runners.claimed_prompt(Repo.reload!(job))

      assert prompt =~
               ~s[##{inner.id} "Inner" (job ##{epic_job.id} on linux-box): your docs/** meets its docs/manual.md]
    end
  end

  describe "under hold (lanes: true)" do
    test "the start is refused, the job held and the prompt has no Lanes block", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"lanes" => true})
      running = card(ctx.doing, "Running", "lib/**")
      working_job_fixture(running)
      next = card(ctx.todo, "Next", "lib/a.ex")

      assert {:error, :unprocessable_entity, _} =
               Boards.move_card(next.id, ctx.doing.id, nil, actor: ctx.agent)

      {:ok, job} = queue(next)
      assert Map.has_key?(Lanes.held_cards(board.id), next.id)
      refute Runners.claimed_prompt(Repo.reload!(job)) =~ "Lanes (advisory)"
    end
  end

  test "lane_hog doesn't apply under advise: nothing is held", ctx do
    board = mode(ctx.board, "advise")
    running = card(ctx.doing, "Running", "lib/**")
    working_job_fixture(running)
    {:ok, job} = queue(card(ctx.todo, "Next", "lib/a.ex"))
    later = DateTime.add(job.inserted_at, 10 * 3600)
    ctx_ = %Context{board: board, now: later}
    assert LaneHog.detect(ctx_, %{"hours" => 4}) == []
  end
end
