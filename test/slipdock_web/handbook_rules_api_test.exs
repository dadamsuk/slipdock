defmodule SlipdockWeb.HandbookRulesAPITest do
  @moduledoc """
  The rules for a set of paths over the wire (#1774): `GET
  /api/boards/:board/handbook?paths=…` answers them, and `get_card` and the
  REST card carry the rules for the card's lane paths in `handbook`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Handbook, Wiki}

  defp token_conn(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp get_card(conn, id) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "get_card", arguments: %{"card" => id}}
      })
    )
    |> json_response(200)
    |> get_in(["result", "structuredContent"])
  end

  setup %{user: user} do
    board = board_fixture(%{}, owner: user)
    {:ok, _} = Handbook.install(user, board)
    data = Enum.find(Handbook.find(board).pages, &(&1.title == "Data model"))

    {:ok, _} =
      Wiki.update_page(data, %{
        "front_matter" => "---\nhandbook: data-model\ncovers: [priv/repo/**]\n---\n",
        "body" =>
          "# Data model\n\n## Rules\n\n" <>
            "- **DATA-1** should · judgement · Prefer a new column to a cast.\n" <>
            "- **DATA-2** must · test/app/migrations_test.exs · Never edit a run migration.\n"
      })

    # The Principles page's worked example (1.5.0) applies to every path: kept out of
    # these, which are about the paths. Slipdock.HandbookTest covers them.
    prin = Enum.find(Handbook.find(board).pages, &(&1.title == "Principles"))
    {:ok, _} = Wiki.update_page(prin, %{"body" => "# Principles\n\n## Rules\n"})

    [col | _] = board.columns
    %{board: board, col: col}
  end

  defp rules(conn, board, query) do
    conn
    |> get("/api/boards/#{board.code}/handbook?" <> URI.encode_query(query))
    |> json_response(200)
  end

  test "?paths= gives the rules that apply, must first", %{user: user, board: board} do
    got = rules(token_conn(user), board, paths: "README.md,priv/repo/migrations/1_a.exs")

    assert got["board"]["code"] == board.code
    assert got["handbook"]["paths"] == ["README.md", "priv/repo/migrations/1_a.exs"]
    assert Enum.map(got["handbook"]["rules"], & &1["id"]) == ["DATA-2", "DATA-1"]

    assert %{
             "severity" => "must",
             "check" => "test/app/migrations_test.exs",
             "scope" => ["priv/repo/**"]
           } =
             hd(got["handbook"]["rules"])
  end

  test "paths as newlines or a list, and none that match", %{user: user, board: board} do
    conn = token_conn(user)
    assert [_, _] = rules(conn, board, paths: "a.ex\npriv/repo/x.exs")["handbook"]["rules"]

    listed =
      conn
      |> get("/api/boards/#{board.code}/handbook?paths[]=priv/repo/x.exs")
      |> json_response(200)

    assert length(listed["handbook"]["rules"]) == 2
    assert rules(conn, board, paths: "lib/a.ex")["handbook"]["rules"] == []
    assert rules(conn, board, paths: "")["handbook"]["rules"] == []
  end

  test "a read-only token can ask", %{user: user, board: board} do
    got = rules(token_conn(user, scope: "read"), board, paths: "priv/repo/x.exs")
    assert length(got["handbook"]["rules"]) == 2
  end

  test "a board without a handbook answers null", %{user: user} do
    bare = board_fixture(%{}, owner: user)
    assert rules(token_conn(user), bare, paths: "a.ex")["handbook"] == nil
  end

  test "a reader without access gets nothing", %{user: user, board: board} do
    other = board_fixture(%{}, owner: user)
    conn = token_conn(user, scope_boards: [other.id])

    assert conn
           |> get("/api/boards/#{board.code}/handbook?paths=priv/repo/x.exs")
           |> json_response(403)

    stranger = user_fixture("rules-api-stranger@example.com")

    assert token_conn(stranger)
           |> get("/api/boards/#{board.code}/handbook?paths=priv/repo/x.exs")
           |> json_response(404)
  end

  test "get_card and the REST card carry the rules for the card's paths",
       %{user: user, col: col} do
    card = card_fixture(col, %{"title" => "Add a column"})
    {:ok, _} = Boards.update_card(card, %{"paths" => ["priv/repo/migrations/**"]})

    mcp = get_card(token_conn(user), card.id)["handbook"]
    rest = (user |> token_conn() |> get("/api/cards/#{card.id}") |> json_response(200))["card"]

    assert mcp == rest["handbook"]
    assert Enum.map(mcp["rules"], & &1["id"]) == ["DATA-2", "DATA-1"]
    assert mcp["rules_more"] == 0
  end

  test "a card without paths carries no rules", %{user: user, col: col} do
    card = card_fixture(col, %{"title" => "Add a column in priv/repo/migrations"})
    refute Map.has_key?(get_card(token_conn(user), card.id)["handbook"], "rules")
  end
end
