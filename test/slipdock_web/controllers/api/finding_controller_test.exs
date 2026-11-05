defmodule SlipdockWeb.API.FindingControllerTest do
  @moduledoc """
  Findings over HTTP (W-2310 §Findings): listed on the tree's root board with
  filters, triaged by a writer, refused to a reader's writes, a read-only
  token and a stranger; and a card's open count on GET /api/cards/:id.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Repo}
  alias Slipdock.Findings.Finding

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(Enum.at(board.columns, 1), %{"title" => "Taught"})
    reader = user_fixture("findings-reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    stranger = user_fixture("findings-stranger@example.com")

    {:ok, _} =
      Boards.add_comment(card, "- Findings:\n  - gotcha: one\n  - rule: two", by: owner)

    [one, two] = Repo.all(from(f in Finding, where: f.card_id == ^card.id, order_by: f.id))

    %{
      board: board,
      card: card,
      owner: owner,
      reader: reader,
      stranger: stranger,
      one: one,
      two: two
    }
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp read_only(user) do
    {token, _} = Accounts.create_api_token(user, "ro", scope: "read")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp list(user, board, query \\ "") do
    as(user) |> get("/api/boards/#{board.code}/findings#{query}") |> json_response(200)
  end

  test "a reader lists the open findings, with the card, kind and source", ctx do
    assert %{"board_id" => id, "findings" => [two, one]} = list(ctx.reader, ctx.board)
    assert id == ctx.board.id
    assert one["kind"] == "gotcha" and one["text"] == "one" and one["source"] == "agent"
    assert one["status"] == "open" and one["count"] == 1
    assert one["card"] == %{"id" => ctx.card.id, "title" => "Taught", "board_id" => ctx.board.id}
    assert two["kind"] == "rule"
  end

  test "filters by kind and status, and a bad since is a 422", ctx do
    assert %{"findings" => [%{"kind" => "rule"}]} = list(ctx.reader, ctx.board, "?kind=rule")
    assert %{"findings" => []} = list(ctx.reader, ctx.board, "?status=dismissed")
    assert %{"findings" => [_, _]} = list(ctx.reader, ctx.board, "?since=7")

    assert %{"error" => "since is" <> _} =
             as(ctx.reader)
             |> get("/api/boards/#{ctx.board.code}/findings?since=soon")
             |> json_response(422)
  end

  test "a sub-board's ref lists the root's findings", ctx do
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(ctx.card, t)
    assert %{"board_id" => id, "findings" => [_, _]} = list(ctx.owner, sub)
    assert id == ctx.board.id
  end

  test "a writer dismisses, promotes with a note, and merges", ctx do
    assert %{"finding" => %{"status" => "dismissed"}} =
             as(ctx.owner)
             |> patch("/api/findings/#{ctx.one.id}", %{"action" => "dismiss"})
             |> json_response(200)

    assert %{"finding" => %{"status" => "promoted", "note" => "W-1950 §Tests TEST-9"}} =
             as(ctx.owner)
             |> patch("/api/findings/#{ctx.two.id}", %{
               "action" => "promote",
               "note" => "W-1950 §Tests TEST-9"
             })
             |> json_response(200)

    {:ok, _} = Slipdock.Findings.triage(ctx.one, "reopen")

    assert %{"finding" => %{"status" => "merged", "merged_into_id" => into}} =
             as(ctx.owner)
             |> patch("/api/findings/#{ctx.one.id}", %{"action" => "merge", "into" => ctx.two.id})
             |> json_response(200)

    assert into == ctx.two.id
    assert Repo.get!(Finding, ctx.two.id).count == 2
  end

  test "a bad change is a 422 that says why", ctx do
    assert %{"error" => "unknown change" <> _} =
             as(ctx.owner)
             |> patch("/api/findings/#{ctx.one.id}", %{"action" => "burn"})
             |> json_response(422)

    assert %{"error" => "say which" <> _} =
             as(ctx.owner)
             |> patch("/api/findings/#{ctx.one.id}", %{"action" => "merge"})
             |> json_response(422)
  end

  test "readers and read-only tokens can't triage; strangers see nothing", ctx do
    assert as(ctx.reader)
           |> patch("/api/findings/#{ctx.one.id}", %{"action" => "dismiss"})
           |> json_response(403)

    assert read_only(ctx.owner)
           |> patch("/api/findings/#{ctx.one.id}", %{"action" => "dismiss"})
           |> json_response(403)

    assert as(ctx.stranger) |> get("/api/boards/#{ctx.board.code}/findings") |> json_response(404)

    assert as(ctx.stranger)
           |> patch("/api/findings/#{ctx.one.id}", %{"action" => "dismiss"})
           |> json_response(404)

    assert as(ctx.owner)
           |> patch("/api/findings/999999999", %{"action" => "dismiss"})
           |> json_response(404)

    assert Repo.get!(Finding, ctx.one.id).status == "open"
  end

  test "GET /api/cards/:id carries the open count", ctx do
    assert %{"card" => %{"findings" => 2}} =
             as(ctx.reader) |> get("/api/cards/#{ctx.card.id}") |> json_response(200)
  end

  describe "the docs" do
    test "the guide has a Findings section of its own, indexed in the short guide" do
      assert {:ok, section} = SlipdockWeb.APIGuide.section("findings", [])
      assert section =~ "## Findings"
      assert section =~ "Findings: none"

      for kind <- ~w(gotcha rule handbook-wrong tooling process),
          do: assert(section =~ "- #{kind}:")

      assert section =~ "would the next pass, on a different card, have done"
      assert section =~ "GET /api/boards/:board/findings"
      assert section =~ "PATCH /api/findings/:id"
      assert SlipdockWeb.APIGuide.short() =~ "`findings`"
    end

    test "agents.md, the README and the manual describe them" do
      agents = File.read!("docs/agents.md")
      assert agents =~ "**Findings.**"
      assert agents =~ "slipdock findings <board>"

      readme = File.read!("README.md")
      assert readme =~ "**Findings**"
      assert readme =~ "docs/manual.md#findings"

      manual = File.read!("docs/manual.md")
      assert manual =~ "## Findings"
      assert manual =~ "slipdock finding 42 merge --into 41"
      assert manual =~ "PATCH /api/findings/:id"
    end
  end
end
