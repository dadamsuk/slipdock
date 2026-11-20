defmodule SlipdockWeb.SensitivePathsTest do
  @moduledoc """
  A board's sensitive paths (#3519): the defaults, the owner's own list
  through `set-board`, and the merge job's claim carrying them and a
  person's approval of its commit.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Boards.{Board, Card}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Sensitive", "code" => unique_code()}, owner: user)
    %{board: board}
  end

  describe "the setting" do
    test "a board starts with the defaults", ctx do
      assert ctx.board.sensitive_paths == nil
      paths = Board.sensitive_paths(ctx.board)
      assert paths == Board.default_sensitive_paths()

      for p <-
            ~w(.github/workflows/** .git/hooks/** .claude/** **/Makefile **/package.json .gitconfig),
          do: assert(p in paths, p)
    end

    test "text one per line or comma-separated, a list, default and none", ctx do
      {:ok, b} =
        Boards.update_board(ctx.board, %{"sensitive_paths" => "ci/**\nMakefile, deploy/*.sh"})

      assert b.sensitive_paths == ["ci/**", "Makefile", "deploy/*.sh"]

      {:ok, b} = Boards.update_board(b, %{"sensitive_paths" => ["a/**", " ", "a/**"]})
      assert Board.sensitive_paths(b) == ["a/**"]

      {:ok, b} = Boards.update_board(b, %{"sensitive_paths" => ""})
      assert Board.sensitive_paths(b) == []

      {:ok, b} = Boards.update_board(b, %{"sensitive_paths" => "default"})
      assert Board.sensitive_paths(b) == Board.default_sensitive_paths()
    end

    test "too many, or one that isn't a path, is refused", ctx do
      assert {:error, cs} =
               Boards.update_board(ctx.board, %{"sensitive_paths" => [String.duplicate("a", 201)]})

      assert Slipdock.DataCase.errors_on(cs).sensitive_paths |> hd() =~ "aren't paths"

      many = for i <- 1..101, do: "p#{i}"
      assert {:error, cs} = Boards.update_board(ctx.board, %{"sensitive_paths" => many})
      assert Slipdock.DataCase.errors_on(cs).sensitive_paths |> hd() =~ "at most 100"
    end

    test "the owner sets it over REST, and the board says it", ctx do
      body =
        ctx.conn
        |> put_req_header("accept", "application/json")
        |> patch(~p"/api/boards/#{ctx.board.code}", %{"sensitive_paths" => "ci/**,Makefile"})
        |> json_response(200)

      assert body["board"]["sensitive_paths"] == ["ci/**", "Makefile"]
      assert Repo.get!(Board, ctx.board.id).sensitive_paths == ["ci/**", "Makefile"]
    end
  end

  describe "the merge job's claim" do
    setup ctx do
      card = card_fixture(hd(ctx.board.columns), %{"title" => "Ship"})

      card
      |> Ecto.Changeset.change(
        evidence_pr: "https://github.com/acme/app/pull/7",
        evidence_commit: "abc1234"
      )
      |> Repo.update!()

      {:ok, runner, token} = Runners.create_runner(ctx.board, %{"name" => "m", "pool" => "dev"})
      Runners.report_kinds(runner, "claude,merge")
      %{card: Repo.get!(Card, card.id), token: token}
    end

    defp claim(ctx) do
      {:ok, _} = Runners.queue(ctx.card, %{pool: "dev", kind: "merge", prompt: ""})

      build_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> post("/api/runner/claim?wait=0")
    end

    test "carries the board's paths, and no approval", ctx do
      conn = claim(ctx)

      assert get_resp_header(conn, "x-sensitive-paths") == [
               Enum.join(Board.default_sensitive_paths(), ",")
             ]

      assert get_resp_header(conn, "x-merge-approved") == []
    end

    test "says a person approved this commit, and only this one", ctx do
      ctx.card |> Ecto.Changeset.change(merge_approved_commit: "abc1234") |> Repo.update!()
      assert get_resp_header(claim(ctx), "x-merge-approved") == ["1"]
    end

    test "an approval of another commit doesn't count", ctx do
      ctx.card |> Ecto.Changeset.change(merge_approved_commit: "fff0000") |> Repo.update!()
      assert get_resp_header(claim(ctx), "x-merge-approved") == []
    end

    test "a board with none sends no paths", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"sensitive_paths" => ""})
      assert get_resp_header(claim(ctx), "x-sensitive-paths") == []
    end
  end
end
