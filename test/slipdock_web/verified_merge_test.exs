defmodule SlipdockWeb.VerifiedMergeTest do
  @moduledoc """
  Ship by PR 4 (#1657): on a board that ships by pull request, accepting a
  card (from the panel, REST, MCP or `Verified.decide/5`) queues one merge
  job instead of completing it, routed with no setting; the merge finishing
  completes the card with the merge commit, a failed one sends it back with
  the reason; with no runner that can merge, the card says so and a person
  marks it merged by hand. Push boards are unchanged.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Runners, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

  @pr "https://github.com/acme/app/pull/7"
  @sha "abc1234def5678abc1234def5678abc1234def56"

  setup %{user: user} do
    board = board_fixture(%{"name" => "Merges", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

    [_backlog, todo, doing, done] = board.columns
    card = card_fixture(doing, %{"title" => "Work"})

    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: user.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: user.id, agent: "checker"}

    %{
      board: board,
      todo: todo,
      doing: doing,
      done: done,
      card: card,
      builder: builder,
      checker: checker
    }
  end

  defp submit(card, ctx) do
    {:ok, card} =
      Boards.update_card(
        Repo.get!(Card, card.id),
        %{"completed" => true, "evidence_pr" => @pr, "evidence_commit" => "abc1234"},
        actor: ctx.builder
      )

    assert card.verify_state == "pending"
    card
  end

  defp merger(ctx, pool \\ "dev", kinds \\ "claude,merge") do
    {:ok, runner, token} =
      Runners.create_runner(ctx.board, %{"name" => "m-#{pool}", "pool" => pool})

    {Runners.report_kinds(runner, kinds), token}
  end

  defp accept(card, ctx),
    do: Verified.decide(Repo.get!(Card, card.id), "accept", %{}, ctx.checker, ctx.user)

  defp merge_jobs(card),
    do: Repo.all(from(j in Job, where: j.card_id == ^card.id and j.kind == "merge"))

  defp comments(card),
    do: Repo.all(from(c in Boards.Comment, where: c.card_id == ^card.id, select: c.body))

  defp api(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "accepting" do
    test "queues one merge job and leaves the card merging, in progress", ctx do
      {_runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)

      {:ok, card} = accept(card, ctx)

      assert card.verify_state == "merging"
      refute card.completed
      refute "review" in card.flags
      assert card.column_id == ctx.doing.id
      assert [%Job{pool: "dev", status: "queued"} = job] = merge_jobs(card)
      assert Runners.merge_target(job) == %{pr: @pr, commit: "abc1234"}
      assert Verified.merge_status(card) == :queued
      assert Enum.any?(comments(card), &(&1 =~ "merging #{@pr}"))
    end

    test "over REST and MCP verify_card the same", ctx do
      {_runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)

      ctx.user
      |> api("rest-checker")
      |> post(~p"/api/cards/#{card.id}/verify", %{"decision" => "accept"})
      |> json_response(200)

      assert Repo.get!(Card, card.id).verify_state == "merging"
      assert length(merge_jobs(card)) == 1

      other = card_fixture(ctx.doing, %{"title" => "Other"}) |> submit(ctx)

      ctx.user
      |> api("mcp-checker")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "verify_card", arguments: %{card: other.id, decision: "accept"}}
        })
      )
      |> json_response(200)

      assert Repo.get!(Card, other.id).verify_state == "merging"
      assert length(merge_jobs(other)) == 1
    end

    test "from the card panel, as a person", ctx do
      {_runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card}")
      view |> element("#verify-accept") |> render_click()

      assert Repo.get!(Card, card.id).verify_state == "merging"
      assert length(merge_jobs(card)) == 1
      assert has_element?(view, "#card-merging", "A runner is merging")
      assert has_element?(view, "#verify-merged")
    end

    test "on a push board accepting completes the card as before, with no merge job", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"ship_via" => "push"})
      {_runner, _} = merger(%{ctx | board: board})
      card = submit(ctx.card, ctx)

      {:ok, card} = accept(card, ctx)

      assert card.verify_state == "accepted"
      assert card.completed
      assert card.column_id == ctx.done.id
      assert merge_jobs(card) == []
    end
  end

  describe "routing, with no setting" do
    test "the pool of the runner that built the card, when it takes merge jobs", ctx do
      {_any, _} = merger(ctx, "any")
      {builder_runner, _} = merger(ctx, "build")
      {:ok, built} = Runners.queue(ctx.card, %{pool: "build", kind: "claude", prompt: "go"})
      %{id: id} = Runners.claim(builder_runner)
      assert id == built.id
      {:ok, _} = Runners.finish(builder_runner, id, %{exit: "0"})

      card = submit(ctx.card, ctx)
      assert Verified.merge_pool(card) == "build"
      {:ok, _} = accept(card, ctx)
      assert [%Job{pool: "build"}] = merge_jobs(card)
    end

    test "else any pool with a runner that takes merge jobs; older runners never", ctx do
      {builder_runner, _} = merger(ctx, "build", "claude")
      {:ok, _old, _} = Runners.create_runner(ctx.board, %{"name" => "old", "pool" => "old"})
      {_other, _} = merger(ctx, "other")
      {:ok, built} = Runners.queue(ctx.card, %{pool: "build", kind: "claude", prompt: "go"})
      %{id: id} = Runners.claim(builder_runner)
      assert id == built.id

      assert ctx.card |> submit(ctx) |> Verified.merge_pool() == "other"
    end

    test "with none that can, no job: the card and the panel say so", ctx do
      {_old, _} = merger(ctx, "dev", "claude")
      card = submit(ctx.card, ctx)

      {:ok, card} = accept(card, ctx)

      assert card.verify_state == "merging"
      assert merge_jobs(card) == []
      assert Verified.merge_status(card) == :none
      assert Enum.any?(comments(card), &(&1 =~ "**No runner can merge this.**"))
      assert Enum.any?(comments(card), &(&1 =~ "slipdock verify #{card.id} merged"))

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card}")
      assert has_element?(view, "#card-no-merger")
    end
  end

  describe "the merge job ending" do
    setup ctx do
      {runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)
      {:ok, _} = accept(card, ctx)
      %{id: id} = Runners.claim(runner)
      %{runner: runner, merging: Repo.get!(Card, card.id), job_id: id}
    end

    test "done with a merge commit completes the card with it, in Done", ctx do
      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "0", merged: @sha})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.completed
      assert card.verify_state == "accepted"
      assert card.merge_sha == @sha
      assert card.column_id == ctx.done.id
      assert Enum.any?(comments(card), &(&1 =~ "**Merged** by runner m-dev as `#{@sha}`"))
      assert SlipdockWeb.API.JSON.card(Boards.get_card!(card.id)).merge_sha == @sha
    end

    test "failed sends it back to the top of To Do with the reason, for rework", ctx do
      {:ok, _} =
        Runners.finish(ctx.runner, ctx.job_id, %{
          exit: "2",
          output: "checking\nmerge: #{@pr}'s head is 999, not the accepted commit abc1234\n"
        })

      card = Repo.get!(Card, ctx.merging.id)
      refute card.completed
      assert card.verify_state == "rejected"
      assert card.verify_note =~ "Merge failed (job ##{ctx.job_id}, failed)"
      assert card.verify_note =~ "not the accepted commit abc1234"
      assert card.evidence_pr == nil
      assert card.column_id == ctx.todo.id
      assert card.position == 0
      assert Verified.rejection(card).reason =~ "Merge failed"
      assert Boards.get_card!(card.id).handoff.next_step =~ "Rework: the merge failed"
      assert Enum.any?(comments(card), &(&1 =~ "Rebase `card-#{card.id}`"))
    end

    test "a person cancelling it sends it back too", ctx do
      job = Repo.get!(Job, ctx.job_id)
      {:ok, _} = Runners.cancel_job(job)
      {:ok, _} = Runners.finish(ctx.runner, ctx.job_id, %{exit: "130", status: "cancelled"})

      card = Repo.get!(Card, ctx.merging.id)
      assert card.verify_state == "rejected"
      assert card.verify_note =~ "cancelled"
    end
  end

  describe "Merged it myself" do
    test "a person completes a merging card, cancelling its merge job", ctx do
      {_runner, _} = merger(ctx)
      card = submit(ctx.card, ctx)
      {:ok, _} = accept(card, ctx)
      [job] = merge_jobs(card)

      {:ok, card} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "merged",
          %{"commit" => "ABCDEF1"},
          Actor.web(ctx.user),
          ctx.user
        )

      assert card.completed
      assert card.verify_state == "accepted"
      assert card.merge_sha == "abcdef1"
      assert card.column_id == ctx.done.id
      assert Repo.get!(Job, job.id).status == "cancelled"
      assert Enum.any?(comments(card), &(&1 =~ "**Merged by hand**"))
    end

    test "from the panel, with no runner to merge", ctx do
      card = submit(ctx.card, ctx)
      {:ok, _} = accept(card, ctx)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card}")
      view |> element("#verify-merged") |> render_click()

      card = Repo.get!(Card, card.id)
      assert card.completed
      assert card.merge_sha == nil
    end

    test "not by an agent, not on a card that isn't merging, and only a commit id", ctx do
      card = submit(ctx.card, ctx)

      assert {:error, :conflict, _} =
               Verified.decide(card, "merged", %{}, Actor.web(ctx.user), ctx.user)

      {:ok, card} = accept(card, ctx)

      assert {:error, :forbidden, _} = Verified.decide(card, "merged", %{}, ctx.checker, ctx.user)

      assert {:error, :unprocessable_entity, _} =
               Verified.decide(
                 card,
                 "merged",
                 %{"commit" => "nope"},
                 Actor.web(ctx.user),
                 ctx.user
               )

      refute Repo.get!(Card, card.id).completed
    end
  end
end
