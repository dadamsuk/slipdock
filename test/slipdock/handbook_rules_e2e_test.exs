defmodule Slipdock.HandbookRulesE2ETest do
  @moduledoc """
  Epic #1772, rules you can cite and check, end to end across its subcards:
  a new handbook's pages start with a `## Rules` section (#1773); rules
  written into it are counted, and an item that isn't one is reported with
  its page and line; the rules for a set of paths come back over REST and in
  `get_card` for a card's lane (#1774), the same rules either way.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Handbook, Wiki}
  alias Slipdock.Handbook.Rules

  defp token_conn(user) do
    {token, _} = Accounts.create_api_token(user, "agent", [])

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp handbook(conn, board, query \\ %{}) do
    conn
    |> get("/api/boards/#{board.code}/handbook?" <> URI.encode_query(query))
    |> json_response(200)
    |> Map.fetch!("handbook")
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

  defp page(board, title), do: Enum.find(Handbook.find(board).pages, &(&1.title == title))

  defp key(page) do
    [_, key] = Regex.run(~r/^handbook:\s*(\S+)/m, page.front_matter)
    key
  end

  # Appends items under the page's own `## Rules` (the Tool's skeleton), and
  # narrows the page's covers so the paths below are predictable.
  defp add_rules(page, covers, items) do
    front = String.replace(page.front_matter, ~r/^covers:.*$/m, "covers: #{covers}")
    [before, rest] = String.split(page.body, "## Rules", parts: 2)
    body = before <> "## Rules" <> String.trim_trailing(rest) <> "\n\n" <> items

    {:ok, _} = Wiki.update_page(page, %{"front_matter" => front, "body" => body})
  end

  test "install, write rules, then ask for them by path, over REST and on a card",
       %{user: user} do
    board = board_fixture(%{"name" => "Rules end to end"}, owner: user)
    {:ok, _} = Handbook.install(user, board)
    conn = token_conn(user)

    # A new handbook: every section page has a Rules section, empty but on
    # Principles, whose worked example (1.5.0) is a `should` that applies
    # everywhere; nothing to report.
    assert [_ | _] = sections = Handbook.find(board).pages
    assert Enum.all?(sections, &(&1.body =~ "## Rules"))
    assert %{"count" => 1, "must" => 0, "problems" => []} = handbook(conn, board)["rules"]
    prin = ["PRIN-1"]

    data = page(board, "Data model")
    pre = Rules.prefix(key(data))

    add_rules(data, "[priv/repo/**]", """
    - **#{pre}-1** must · test/app/migrations_test.exs · Never edit a migration that has run.
    - **#{pre}-2** should · scope priv/repo/seeds.exs · judgement · Seeds stay idempotent.
    - **#{pre}-3** must · Missing its check.
    """)

    # Written: two rules count, and the third is reported where it is.
    summary = handbook(conn, board)["rules"]
    assert summary["count"] == 3
    assert summary["must"] == 1
    assert [%{"page" => code, "line" => line, "item" => item}] = summary["problems"]
    assert code == data.code
    assert is_integer(line) and line > 0
    assert item =~ "#{pre}-3"

    # By path: a migration gets the must rule; the seeds file both, must first;
    # a path nothing covers, neither; the principles come with every path.
    ids = fn paths ->
      Enum.map(handbook(conn, board, paths: paths)["rules"], & &1["id"])
    end

    assert ids.("priv/repo/migrations/1_add.exs") == ["#{pre}-1" | prin]
    assert ids.("priv/repo/seeds.exs") == ["#{pre}-1", "#{pre}-2" | prin]
    assert ids.("README.md") == prin

    # A card whose lane is the migrations carries the same rules as REST.
    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "Add a column"})
    {:ok, _} = Boards.update_card(card, %{"paths" => ["priv/repo/migrations/**"]})

    on_card = get_card(conn, card.id)["handbook"]
    by_path = handbook(conn, board, paths: "priv/repo/migrations/**")["rules"]

    assert Enum.map(on_card["rules"], & &1["id"]) == ["#{pre}-1" | prin]
    assert on_card["rules_more"] == 0

    assert %{"severity" => "must", "check" => "test/app/migrations_test.exs"} =
             hd(on_card["rules"])

    assert hd(on_card["rules"])["id"] == hd(by_path)["id"]

    # Fixing the bad item clears the report and adds the rule.
    data = page(board, "Data model")

    {:ok, _} =
      Wiki.update_page(data, %{
        "body" =>
          String.replace(
            data.body,
            "must · Missing its check.",
            "must · judgement · Has its check now."
          )
      })

    assert %{"count" => 4, "must" => 2, "problems" => []} = handbook(conn, board)["rules"]
    assert ids.("priv/repo/migrations/1_add.exs") == ["#{pre}-1", "#{pre}-3" | prin]
  end
end
