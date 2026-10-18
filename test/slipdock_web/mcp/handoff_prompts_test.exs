defmodule SlipdockWeb.MCP.HandoffPromptsTest do
  @moduledoc """
  `resume` and `leave-handoff` (W-1805), built on the handoff note (W-1804):
  the rendered text carries the card's handoff, open subcards and comments,
  takes a card as `129`, `#129` or `#129 title`, and refuses a card the token
  can't read.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}
  alias SlipdockWeb.MCP.Prompts

  setup %{user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "deliv2"}, owner: user)
    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "Fix the retry", "description" => "Backoff is wrong."})
    blocker = card_fixture(col, %{"title" => "Upgrade the client"})
    {:ok, _} = Boards.add_dependency(card, blocker)
    {:ok, _} = Boards.add_comment(card, "first look: it doubles")
    {:ok, _} = Boards.add_comment(card, "found it in the jitter")

    {:ok, _} =
      Boards.leave_handoff(card, user, %{
        next_step: "Write the failing test",
        body: "State: cause found.\nGotchas: the clock is mocked.",
        via: "ui"
      })

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs2hp"}, owner: stranger)
    secret = card_fixture(hd(theirs.columns), %{"title" => "Their secret"})
    %{board: board, col: col, card: card, blocker: blocker, secret: secret}
  end

  defp prompt(conn, name, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: %{name: name, arguments: args}
      })
    )
    |> json_response(200)
  end

  defp text!(body) do
    assert %{"result" => %{"messages" => [%{"content" => %{"text" => text}}]}} = body
    assert String.length(text) <= Prompts.max_chars()
    text
  end

  test "both are listed after the first three, each needing a card", %{conn: conn} do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "prompts/list"}))
      |> json_response(200)

    by_name = Map.new(body["result"]["prompts"], &{&1["name"], &1})

    for name <- ["resume", "leave-handoff"] do
      assert [%{"name" => "card", "required" => true}] = by_name[name]["arguments"]
    end
  end

  describe "resume" do
    test "the handoff first, then blockers, description and comments", ctx do
      text = ctx.conn |> prompt("resume", %{card: "#{ctx.card.id}"}) |> text!()

      assert text =~ "##{ctx.card.id} Fix the retry where it was left"
      assert text =~ "Left off: Write the failing test"
      assert text =~ "Gotchas: the clock is mocked."
      assert text =~ "Blocked by: ##{ctx.blocker.id} Upgrade the client"
      assert text =~ "Backoff is wrong."
      [_, comments] = String.split(text, "## Latest comments", parts: 2)
      assert comments =~ ~r/found it in the jitter.*first look: it doubles/s
      assert text =~ "the one next step"
      assert text =~ ~r/Tools to use: get_card, .*\.$/
      refute text =~ "read-only"
    end

    test "takes #id and the '#id title' completion offers", ctx do
      for ref <- ["##{ctx.card.id}", "##{ctx.card.id} Fix the retry", " #{ctx.card.id} "] do
        assert ctx.conn |> prompt("resume", %{card: ref}) |> text!() =~ "Left off:"
      end
    end

    test "a card without a handoff says so", ctx do
      bare = card_fixture(ctx.col, %{"title" => "Bare"})
      assert ctx.conn |> prompt("resume", %{card: "#{bare.id}"}) |> text!() =~ "No handoff note"
    end

    test "a cleared handoff reads as none", ctx do
      {:ok, _} = Boards.clear_handoff(ctx.card, ctx.user, %{via: "ui"})
      text = ctx.conn |> prompt("resume", %{card: "#{ctx.card.id}"}) |> text!()
      assert text =~ "No handoff note"
      refute text =~ "Write the failing test"
    end

    test "an epic's open subcards are listed; done ones aren't", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      [sub_col | _] = Boards.get_board!(sub.id).columns
      open = card_fixture(sub_col, %{"title" => "Open child"})
      card_fixture(sub_col, %{"title" => "Done child", "completed" => true})

      text = ctx.conn |> prompt("resume", %{card: "#{ctx.card.id}"}) |> text!()
      assert text =~ "## Open subcards"
      assert text =~ "##{open.id} Open child"
      refute text =~ "Done child"
    end

    test "a card it can't read, a bad number and a missing card are -32602", ctx do
      for args <- [%{card: "#{ctx.secret.id}"}, %{card: "abc"}, %{card: "12x"}, %{}] do
        assert %{"error" => %{"code" => -32602}} = prompt(ctx.conn, "resume", args)
      end

      refute inspect(prompt(ctx.conn, "resume", %{card: "#{ctx.secret.id}"})) =~ "Their secret"
    end

    test "a token scoped to another board can't resume this card", ctx do
      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)
      {token, _} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [other.id])
      conn = put_req_header(ctx.conn, "authorization", "Bearer " <> token)
      assert %{"error" => %{"message" => msg}} = prompt(conn, "resume", %{card: "#{ctx.card.id}"})
      assert msg =~ "scope"
    end
  end

  describe "leave-handoff" do
    test "shows the current handoff and says how to call leave_handoff", ctx do
      text = ctx.conn |> prompt("leave-handoff", %{card: "##{ctx.card.id}"}) |> text!()
      assert text =~ "Leave a handoff on ##{ctx.card.id} Fix the retry"
      assert text =~ "Left off: Write the failing test"
      assert text =~ "Call leave_handoff with card #{ctx.card.id}"
      assert text =~ "next_step" and text =~ "Pointers"
      assert text =~ ~r/Tools to use: leave_handoff, get_card\.$/
    end

    test "a read-only token is told it will only report", ctx do
      {token, _} = Accounts.create_api_token(ctx.user, "ro", scope: "read")
      conn = put_req_header(ctx.conn, "authorization", "Bearer " <> token)
      assert conn |> prompt("leave-handoff", %{card: "#{ctx.card.id}"}) |> text!() =~ "read-only"
    end

    test "a stranger's card is refused", ctx do
      assert %{"error" => %{"code" => -32602}} =
               prompt(ctx.conn, "leave-handoff", %{card: "#{ctx.secret.id}"})
    end
  end
end
