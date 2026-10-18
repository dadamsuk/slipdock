defmodule SlipdockWeb.MCP.CompletionsTest do
  @moduledoc """
  `completion/complete` (W-1805): board codes by prefix and access, cards as
  `#id title` within a board, and nothing suggested that the token can't read.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}
  alias SlipdockWeb.MCP.Completions

  setup %{user: user} do
    alpha = board_fixture(%{"name" => "Alpha", "code" => "alpha9"}, owner: user)
    almond = board_fixture(%{"name" => "Almond", "code" => "almond9"}, owner: user)
    beta = board_fixture(%{"name" => "Beta", "code" => "beta9"}, owner: user)
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Alpine", "code" => "alpine9"}, owner: stranger)
    %{alpha: alpha, almond: almond, beta: beta, theirs: theirs}
  end

  defp complete(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "completion/complete", params: params})
    )
    |> json_response(200)
  end

  defp board_values(conn, value, prompt \\ "triage") do
    body =
      complete(conn, %{
        ref: %{type: "ref/prompt", name: prompt},
        argument: %{name: "board", value: value}
      })

    body["result"]["completion"]["values"]
  end

  defp context(user, token \\ %{scope: "write"}), do: %{user: user, token: token, base_url: ""}

  test "initialize advertises completions", %{conn: conn} do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{protocolVersion: "2025-11-25"}
        })
      )
      |> json_response(200)

    assert body["result"]["capabilities"]["completions"] == %{}
  end

  describe "board" do
    test "codes of the boards the token sees, by prefix of code or name", %{conn: conn} do
      assert Enum.sort(board_values(conn, "al")) == ["almond9", "alpha9"]
      assert board_values(conn, "ALPH") == ["alpha9"]
      assert board_values(conn, "Bet") == ["beta9"]
      assert board_values(conn, "zzz") == []
      refute "alpine9" in board_values(conn, "")
    end

    test "a board-scoped token is offered only its boards", ctx do
      {token, _} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [ctx.alpha.id])
      conn = put_req_header(ctx.conn, "authorization", "Bearer " <> token)
      assert board_values(conn, "al") == ["alpha9"]
    end

    test "the answer carries total and hasMore", %{conn: conn} do
      body =
        complete(conn, %{
          ref: %{type: "ref/prompt", name: "weekly-review"},
          argument: %{name: "board", value: "al"}
        })

      assert %{"values" => [_, _], "total" => 2, "hasMore" => false} =
               body["result"]["completion"]
    end
  end

  describe "card" do
    setup %{alpha: alpha, beta: beta, theirs: theirs} do
      [col | _] = alpha.columns
      fix = card_fixture(col, %{"title" => "Fix the retry"})
      feed = card_fixture(col, %{"title" => "Feed the cat"})
      done = card_fixture(col, %{"title" => "Fix done already", "completed" => true})
      gone = card_fixture(col, %{"title" => "Fix archived"})
      {:ok, _} = Boards.archive_card(gone)
      other = card_fixture(hd(beta.columns), %{"title" => "Fix on beta"})
      secret = card_fixture(hd(theirs.columns), %{"title" => "Fix their thing"})

      epic = card_fixture(col, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      deep = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Fix deep down"})

      %{fix: fix, feed: feed, done: done, other: other, secret: secret, deep: deep}
    end

    test "#id title by title words, on the chosen board and its sub-boards", ctx do
      values = Completions.suggest("card", "fix", %{"board" => "alpha9"}, context(ctx.user))

      assert Enum.sort(values) ==
               Enum.sort(["##{ctx.fix.id} Fix the retry", "##{ctx.deep.id} Fix deep down"])
    end

    test "by the start of its number", ctx do
      typed = "#" <> String.slice(to_string(ctx.feed.id), 0..-2//1)
      values = Completions.suggest("card", typed, %{"board" => "alpha9"}, context(ctx.user))
      assert "##{ctx.feed.id} Feed the cat" in values
      assert Enum.all?(values, &String.starts_with?(&1, typed))
    end

    test "with no board chosen, every board the token sees; never a stranger's", ctx do
      values = Completions.suggest("card", "fix", %{}, context(ctx.user))
      assert "##{ctx.other.id} Fix on beta" in values
      assert "##{ctx.fix.id} Fix the retry" in values
      refute Enum.any?(values, &(&1 =~ "their thing"))
    end

    test "a board the token can't see suggests nothing", ctx do
      assert Completions.suggest("card", "fix", %{"board" => "alpine9"}, context(ctx.user)) == []
    end

    test "a scoped token's other boards are left out", ctx do
      {_, token} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [ctx.beta.id])

      assert Completions.suggest("card", "fix", %{}, context(ctx.user, token)) ==
               ["##{ctx.other.id} Fix on beta"]
    end

    test "a % or _ typed is matched literally", ctx do
      assert Completions.suggest("card", "%", %{}, context(ctx.user)) == []
    end
  end

  describe "errors and the rest" do
    test "an unknown prompt is -32602", %{conn: conn} do
      body =
        complete(conn, %{
          ref: %{type: "ref/prompt", name: "nope"},
          argument: %{name: "board", value: ""}
        })

      assert body["error"]["code"] == -32602
      assert body["error"]["message"] =~ "unknown prompt: nope"
    end

    test "an optional board completes too; an argument the prompt lacks, or a resource ref, to nothing",
         ctx do
      assert Enum.sort(board_values(ctx.conn, "al", "plan-my-day")) == ["almond9", "alpha9"]

      body =
        complete(ctx.conn, %{
          ref: %{type: "ref/prompt", name: "triage"},
          argument: %{name: "colour", value: "r"}
        })

      assert body["result"]["completion"]["values"] == []

      body =
        complete(ctx.conn, %{
          ref: %{type: "ref/resource", uri: "slipdock://x"},
          argument: %{name: "id", value: ""}
        })

      assert body["result"]["completion"]["values"] == []
    end

    test "without a ref it is -32602", %{conn: conn} do
      assert complete(conn, %{})["error"]["code"] == -32602
    end
  end
end
