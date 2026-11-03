defmodule Slipdock.Runners.MergeKindTest do
  @moduledoc """
  Ship by PR 3 (#1656), the server's side: runners say which kinds they
  take, merge jobs go only to runners that list merge, a merge job's claim
  carries the pull request and accepted commit, and its finish keeps the
  merge commit.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.{Job, Runner}

  setup do
    board = board_fixture(%{"name" => "Merge", "code" => unique_code()})
    card = card_fixture(hd(board.columns), %{"title" => "Ship"})

    card =
      card
      |> Ecto.Changeset.change(
        evidence_pr: "https://github.com/acme/widgets/pull/7",
        evidence_commit: "abc1234"
      )
      |> Repo.update!()

    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "r", "pool" => "dev"})
    %{board: board, card: card, runner: runner, token: token}
  end

  defp queue(card, kind), do: Runners.queue(card, %{pool: "dev", kind: kind, prompt: "go"})

  describe "report_kinds/2" do
    test "keeps a tidy list, ignoring junk, and leaves it alone when nothing is said", ctx do
      runner = Runners.report_kinds(ctx.runner, "claude, Merge,verify,merge,bad kind!,../x")
      assert runner.kinds == ["bad", "claude", "merge", "verify"]
      assert Repo.get!(Runner, ctx.runner.id).kinds == runner.kinds

      assert SlipdockWeb.API.JSON.runner(Repo.get!(Runner, runner.id)).kinds == runner.kinds
      assert Runners.report_kinds(runner, nil).kinds == runner.kinds
      assert Runners.report_kinds(runner, "").kinds == []
    end

    test "takes_merge? only when merge is listed" do
      refute Runners.takes_merge?(%Runner{kinds: nil})
      refute Runners.takes_merge?(%Runner{kinds: ["claude"]})
      assert Runners.takes_merge?(%Runner{kinds: ["merge"]})
    end
  end

  describe "claim routing" do
    test "a runner that never said its kinds (an older one) is passed over for merge jobs", ctx do
      {:ok, merge} = queue(ctx.card, "merge")
      {:ok, claude} = queue(ctx.card, "claude")

      assert %{id: id} = Runners.claim(ctx.runner)
      assert id == claude.id
      assert Runners.claim(ctx.runner) == nil
      assert Repo.get!(Job, merge.id).status == "queued"
    end

    test "a runner that lists merge takes the merge job", ctx do
      {:ok, merge} = queue(ctx.card, "merge")
      runner = Runners.report_kinds(ctx.runner, "claude,merge")
      assert %{id: id} = Runners.claim(runner)
      assert id == merge.id
    end
  end

  describe "merge_target/1" do
    test "the PR and the verifier's commit, else the builder's", ctx do
      {:ok, job} = queue(ctx.card, "merge")

      assert Runners.merge_target(job) ==
               %{pr: "https://github.com/acme/widgets/pull/7", commit: "abc1234"}

      ctx.card |> Ecto.Changeset.change(verify_commit: "def5678") |> Repo.update!()
      assert Runners.merge_target(job).commit == "def5678"

      {:ok, other} = queue(ctx.card, "claude")
      assert Runners.merge_target(other) == nil
    end
  end

  describe "the HTTP protocol" do
    defp claim(conn, token, kinds) do
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> then(&if(kinds, do: put_req_header(&1, "x-runner-kinds", kinds), else: &1))
      |> post("/api/runner/claim?wait=0")
    end

    test "a merge job's claim carries the PR and the commit; others don't", %{conn: conn} = ctx do
      {:ok, merge} = queue(ctx.card, "merge")
      conn = claim(conn, ctx.token, "claude,merge")

      assert conn.status == 200
      assert get_resp_header(conn, "x-job-id") == [to_string(merge.id)]
      assert get_resp_header(conn, "x-merge-pr") == ["https://github.com/acme/widgets/pull/7"]
      assert get_resp_header(conn, "x-merge-commit") == ["abc1234"]
      assert Repo.get!(Runner, ctx.runner.id).kinds == ["claude", "merge"]

      {:ok, _} = queue(ctx.card, "claude")
      conn = claim(build_conn(), ctx.token, nil)
      assert conn.status == 200
      assert get_resp_header(conn, "x-merge-pr") == []
      # Saying nothing kept what it said before.
      assert Repo.get!(Runner, ctx.runner.id).kinds == ["claude", "merge"]
    end

    test "finish keeps a merge job's merged commit, and only a commit id", %{conn: conn} = ctx do
      {:ok, merge} = queue(ctx.card, "merge")
      200 = claim(conn, ctx.token, "merge").status

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.token)
        |> post("/api/runner/jobs/#{merge.id}/finish?exit=0&merged=ABCDEF1234567")

      assert conn.status == 200
      assert Repo.get!(Job, merge.id).merged_sha == "abcdef1234567"
    end

    test "a merged value that isn't a commit id, or on another kind, is not kept", ctx do
      runner = Runners.report_kinds(ctx.runner, "merge,claude")
      {:ok, merge} = queue(ctx.card, "merge")
      %{id: id} = Runners.claim(runner)
      assert id == merge.id
      {:ok, job} = Runners.finish(runner, id, %{exit: "0", merged: "$(rm -rf /)"})
      assert job.merged_sha == nil

      {:ok, claude} = queue(ctx.card, "claude")
      %{id: id} = Runners.claim(runner)
      assert id == claude.id
      {:ok, job} = Runners.finish(runner, id, %{exit: "0", merged: "abcdef1"})
      assert job.merged_sha == nil
      assert Repo.get!(Card, ctx.card.id)
    end
  end
end
