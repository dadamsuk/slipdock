defmodule SlipdockWeb.API.FindingControllerTest do
  @moduledoc """
  Findings over HTTP (W-2310 §Findings): listed on the tree's root board with
  filters, triaged by a writer, refused to a reader's writes, a read-only
  token and a stranger; and a card's open count on GET /api/cards/:id.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

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
      Boards.Comments.add_comment(card, "- Findings:\n  - gotcha: one\n  - rule: two", by: owner)

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

  # A rule drafted from findings, waiting on a person (#2123).
  defp proposal(board, finding_ids, attrs \\ []) do
    %Slipdock.Gardener.Suggestion{
      board_id: board.id,
      check: "proposal",
      fingerprint: "p#{System.unique_integer([:positive])}",
      explanation: "Finding seen 3 times: add a rule",
      subject: if(finding_ids == [], do: %{}, else: %{"findings" => finding_ids})
    }
    |> struct(attrs)
    |> Repo.insert!()
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

  test "the proposals drafted from them come first, as awaiting (#2123)", ctx do
    assert %{"awaiting" => []} = list(ctx.reader, ctx.board)

    p = proposal(ctx.board, [ctx.one.id])
    proposal(ctx.board, [ctx.one.id], state: "applied")
    proposal(ctx.board, [])

    # The one it names waits on the person, out of the open list (#2767).
    assert %{"awaiting" => [listed], "findings" => [two]} = list(ctx.reader, ctx.board)
    assert two["id"] == ctx.two.id
    assert %{"id" => id, "check" => "proposal", "state" => "open", "findings" => [one]} = listed
    assert id == p.id and one == ctx.one.id
    assert listed["explanation"] == "Finding seen 3 times: add a rule"
  end

  # #2767: deciding it would close the person's proposal, so it isn't triage's.
  test "a finding an open proposal names is waiting, out of the open list", ctx do
    p = proposal(ctx.board, [ctx.one.id])

    assert %{"awaiting" => [_], "findings" => [two]} = list(ctx.reader, ctx.board)
    assert two["id"] == ctx.two.id and two["waiting"] == nil

    assert %{"findings" => [one]} = list(ctx.reader, ctx.board, "?status=waiting")
    assert one["id"] == ctx.one.id and one["status"] == "open" and one["waiting"] == p.id

    assert %{"findings" => [_, _]} = list(ctx.reader, ctx.board, "?status=all")
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

  # #1941: one row per lesson, with the cards it was said on; a runner's
  # tooling only when asked for.
  test "a lesson said on another card is one row with both cards, and scope filters", ctx do
    other = card_fixture(Enum.at(ctx.board.columns, 1), %{"title" => "Again"})

    {:ok, _} =
      Boards.Comments.add_comment(
        other,
        "- Findings:\n  - gotcha: One.\n  - tooling (runner): the installed CLI lags",
        by: ctx.owner
      )

    %{"findings" => findings} = list(ctx.reader, ctx.board)
    assert Enum.map(findings, & &1["text"]) |> Enum.sort() == ["one", "two"]
    one = Enum.find(findings, &(&1["text"] == "one"))
    assert one["count"] == 2 and one["scope"] == "board"
    assert Enum.map(one["cards"], & &1["id"]) == [ctx.card.id, other.id]

    assert %{"findings" => [runner]} = list(ctx.reader, ctx.board, "?scope=runner")
    assert runner["scope"] == "runner" and runner["kind"] == "tooling" and runner["runner"] == nil
    assert %{"findings" => all} = list(ctx.reader, ctx.board, "?scope=all")
    assert length(all) == 3

    assert %{"error" => "scope is board, runner or all"} =
             as(ctx.reader)
             |> get("/api/boards/#{ctx.board.code}/findings?scope=nope")
             |> json_response(422)
  end

  test "a sub-board's ref lists the root's findings", ctx do
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
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

      assert_states(section, "would a card on a different subject want to know")
      assert section =~ "`Findings: none` is the usual answer"
      assert section =~ "GET /api/boards/:board/findings"
      assert section =~ "PATCH /api/findings/:id"
      assert SlipdockWeb.APIGuide.short() =~ "`findings`"
    end

    test "agents.md, the feature digest and the manual describe them" do
      agents = Slipdock.DocsText.read!("docs/agents.md")
      assert agents =~ "**Findings.**"
      assert agents =~ "slipdock findings <board>"

      readme = Slipdock.DocsText.read!("docs/manual/every-feature-in-brief.md")
      assert readme =~ "**Findings**"
      assert readme =~ "(findings.md)"

      manual = Slipdock.DocsText.read!("docs/manual.md")
      assert manual =~ "## Findings"
      assert manual =~ "slipdock finding 42 merge --into 41"
      assert manual =~ "PATCH /api/findings/:id"
    end
  end
end
