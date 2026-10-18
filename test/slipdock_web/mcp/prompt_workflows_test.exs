defmodule SlipdockWeb.MCP.PromptWorkflowsTest do
  @moduledoc """
  The prompts themselves (W-1805), through `prompts/get` on `/mcp`: each
  rendered text carries the live facts — fixture cards appear, archived and
  other people's don't — keeps to the token's scope and names its tools.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias SlipdockWeb.MCP.{Prompts, Tools}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "deliv1"}, owner: user)
    cols = Map.new(board.columns, &{&1.name, &1})
    other = board_fixture(%{"name" => "Elsewhere", "code" => "else1"}, owner: user)
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs1"}, owner: stranger)
    %{board: board, cols: cols, other: other, stranger: stranger, theirs: theirs}
  end

  defp prompt(conn, name, args \\ %{}) do
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
    assert %{"result" => %{"messages" => [%{"role" => "user", "content" => content}]}} = body
    assert content["type"] == "text"
    assert String.length(content["text"]) <= Prompts.max_chars()
    content["text"]
  end

  defp scoped(conn, user, opts) do
    {token, _} = Accounts.create_api_token(user, "scoped", opts)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp mine(col, user, attrs),
    do: card_fixture(col, Map.merge(%{"assignee_ids" => [user.id]}, attrs))

  defp today, do: Date.utc_today()

  test "prompts/list offers the three, in order, with their arguments", %{conn: conn} do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "prompts/list"}))
      |> json_response(200)

    names = Enum.map(body["result"]["prompts"], & &1["name"])
    assert Enum.take(names, 3) == ["plan-my-day", "weekly-review", "triage"]

    triage = Enum.find(body["result"]["prompts"], &(&1["name"] == "triage"))

    assert triage["arguments"] == [
             %{
               "name" => "board",
               "description" => "The board to triage (id, code or name).",
               "required" => true
             }
           ]
  end

  test "every tool a prompt names is a real tool" do
    tools = Enum.map(Tools.every(), & &1.name())

    for prompt <- Prompts.every(), tool <- prompt.tools() do
      assert tool in tools, "#{prompt.name()} names #{tool}"
    end
  end

  describe "plan-my-day" do
    test "my overdue, due-today, in-progress and ready cards; not others'", ctx do
      %{conn: conn, user: user, cols: cols} = ctx

      late =
        mine(cols["To Do"], user, %{"title" => "Late one", "due_date" => Date.add(today(), -2)})

      due = mine(cols["To Do"], user, %{"title" => "Due now", "due_date" => today()})
      doing = mine(cols["In Progress"], user, %{"title" => "Halfway"})
      ready = card_fixture(cols["To Do"], %{"title" => "Up next"})
      gone = mine(cols["To Do"], user, %{"title" => "Archived mine", "due_date" => today()})
      {:ok, _} = Boards.archive_card(gone)
      done = mine(cols["Done"], user, %{"title" => "Finished mine", "completed" => true})
      secret = card_fixture(hd(ctx.theirs.columns), %{"title" => "Their secret"})

      text = conn |> prompt("plan-my-day") |> text!()

      [overdue, rest] = String.split(text, "## Due today", parts: 2)
      assert overdue =~ "##{late.id} Late one"
      assert overdue =~ "Delivery"
      [due_today, rest] = String.split(rest, "## In progress", parts: 2)
      assert due_today =~ "##{due.id} Due now"
      [in_progress, _] = String.split(rest, "## Waking", parts: 2)
      assert in_progress =~ "##{doing.id} Halfway"
      assert text =~ "Delivery (code deliv1, board ##{ctx.board.id}), To Do:\n"
      assert text =~ "##{ready.id} Up next"

      refute text =~ "Archived mine"
      refute text =~ done.title
      refute text =~ secret.title
      assert text =~ "ask me before moving"
      assert text =~ ~r/Tools to use: .*move_card.*\.$/
    end

    test "a snooze waking today is there; one waking later is not", ctx do
      %{conn: conn, user: user, cols: cols} = ctx
      soon = mine(cols["To Do"], user, %{"title" => "Wakes soon"})
      later = mine(cols["To Do"], user, %{"title" => "Wakes later"})
      {:ok, _} = Slipdock.Snooze.snooze(soon, user, DateTime.add(DateTime.utc_now(), 60))
      {:ok, _} = Slipdock.Snooze.snooze(later, user, DateTime.add(DateTime.utc_now(), 3, :day))

      text = conn |> prompt("plan-my-day") |> text!()
      [_, waking] = String.split(text, "## Waking from a snooze today", parts: 2)
      [waking, _] = String.split(waking, "## Top of", parts: 2)
      assert waking =~ "##{soon.id} Wakes soon"
      refute text =~ "Wakes later"
    end

    test "board keeps it to that board; an unknown board is -32602", ctx do
      %{conn: conn, user: user, cols: cols} = ctx
      mine(cols["To Do"], user, %{"title" => "Here", "due_date" => today()})
      mine(hd(ctx.other.columns), user, %{"title" => "There", "due_date" => today()})

      text = conn |> prompt("plan-my-day", %{board: "deliv1"}) |> text!()
      assert text =~ "Here"
      refute text =~ "There"

      assert %{"error" => %{"code" => -32602}} = prompt(conn, "plan-my-day", %{board: "theirs1"})
    end

    test "a board-scoped token's context leaves out its other boards", ctx do
      %{conn: conn, user: user, cols: cols} = ctx
      mine(cols["To Do"], user, %{"title" => "In scope", "due_date" => today()})
      mine(hd(ctx.other.columns), user, %{"title" => "Out of scope", "due_date" => today()})

      text =
        conn |> scoped(user, scope_boards: [ctx.board.id]) |> prompt("plan-my-day") |> text!()

      assert text =~ "In scope"
      refute text =~ "Out of scope"
      refute text =~ "Elsewhere"
    end

    test "a read-only token is told it will only report", ctx do
      text = ctx.conn |> scoped(ctx.user, scope: "read") |> prompt("plan-my-day") |> text!()
      assert text =~ "read-only"
    end

    test "a long list is cut, saying how many more", ctx do
      for i <- 1..20,
          do:
            mine(ctx.cols["To Do"], ctx.user, %{
              "title" => "Late #{i}",
              "due_date" => Date.add(today(), -1)
            })

      text = ctx.conn |> prompt("plan-my-day") |> text!()
      assert text =~ "…and 8 more, use list_cards"
    end
  end

  describe "weekly-review" do
    test "finished, activity, slipped and stale; archived and others' left out", ctx do
      %{conn: conn, cols: cols} = ctx
      shipped = card_fixture(cols["To Do"], %{"title" => "Shipped it"})
      {:ok, _} = Boards.toggle_completed(shipped)

      slipped =
        card_fixture(cols["To Do"], %{
          "title" => "Slipped one",
          "due_date" => Date.add(today(), -3)
        })

      stale = card_fixture(cols["In Progress"], %{"title" => "Gone quiet"})
      old = DateTime.add(DateTime.utc_now(), -10, :day) |> DateTime.truncate(:second)

      Repo.update_all(from(c in Slipdock.Boards.Card, where: c.id == ^stale.id),
        set: [updated_at: old]
      )

      fresh = card_fixture(cols["In Progress"], %{"title" => "Busy one"})

      gone =
        card_fixture(cols["To Do"], %{
          "title" => "Archived slip",
          "due_date" => Date.add(today(), -3)
        })

      {:ok, _} = Boards.archive_card(gone)

      card_fixture(hd(ctx.theirs.columns), %{
        "title" => "Their slip",
        "due_date" => Date.add(today(), -3)
      })

      text = conn |> prompt("weekly-review") |> text!()

      [finished, rest] = String.split(text, "## What happened", parts: 2)
      assert finished =~ "##{shipped.id} Shipped it"
      [happened, rest] = String.split(rest, "## Slipped", parts: 2)
      assert happened =~ "Delivery:"
      [slip, stale_part] = String.split(rest, "## Stale", parts: 2)
      assert slip =~ "##{slipped.id} Slipped one"
      assert stale_part =~ "##{stale.id} Gone quiet"
      refute stale_part =~ fresh.title
      refute slip =~ "Archived slip"
      refute text =~ "Their slip"
      assert text =~ "don't change anything"
      refute text =~ "read-only"
    end

    test "subcards count: a sub-board's slipped card is in the review", ctx do
      epic = card_fixture(ctx.cols["To Do"], %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Boards.get_board!(sub.id)

      deep =
        card_fixture(hd(sub.columns), %{
          "title" => "Deep slip",
          "due_date" => Date.add(today(), -1)
        })

      assert ctx.conn |> prompt("weekly-review", %{board: "deliv1"}) |> text!() =~
               "##{deep.id} Deep slip"
    end

    test "a board-scoped token sees only its board", ctx do
      card_fixture(hd(ctx.other.columns), %{
        "title" => "Other slip",
        "due_date" => Date.add(today(), -3)
      })

      card_fixture(ctx.cols["To Do"], %{
        "title" => "Our slip",
        "due_date" => Date.add(today(), -3)
      })

      text =
        ctx.conn
        |> scoped(ctx.user, scope_boards: [ctx.board.id])
        |> prompt("weekly-review")
        |> text!()

      assert text =~ "Our slip"
      refute text =~ "Other slip"
    end
  end

  describe "triage" do
    test "the intake list's open cards, with the board's lists and tags", ctx do
      tag_fixture(ctx.board, "bug")

      a =
        card_fixture(ctx.cols["Backlog"], %{
          "title" => "Idea one",
          "description" => "  some\n\nwords  "
        })

      b = card_fixture(ctx.cols["Backlog"], %{"title" => "Idea two"})
      card_fixture(ctx.cols["Backlog"], %{"title" => "Old done", "completed" => true})
      gone = card_fixture(ctx.cols["Backlog"], %{"title" => "Archived idea"})
      {:ok, _} = Boards.archive_card(gone)
      card_fixture(ctx.cols["To Do"], %{"title" => "Not intake"})

      text = ctx.conn |> prompt("triage", %{board: "deliv1"}) |> text!()
      assert text =~ "Triage the Backlog list on Delivery"
      assert text =~ "2 open card(s)"
      assert text =~ "Ready list (where kept work goes): To Do"
      assert text =~ "Tags on this board: bug"
      assert text =~ "##{a.id} Idea one, added #{Date.to_iso8601(today())} — some words"
      assert text =~ "##{b.id} Idea two"
      refute text =~ "Old done"
      refute text =~ "Archived idea"
      refute text =~ "Not intake"
      assert text =~ "Wait for my answer"
    end

    test "needs a board; a board it can't see or without an intake list is refused", ctx do
      assert %{"error" => %{"code" => -32602, "message" => msg}} = prompt(ctx.conn, "triage")
      assert msg =~ "triage needs the board argument"

      assert %{"error" => %{"code" => -32602}} = prompt(ctx.conn, "triage", %{board: "theirs1"})

      flat = board_fixture(%{"name" => "Flat", "code" => "flat1"}, owner: ctx.user)
      {:ok, _} = flat.columns |> Enum.find(&(&1.name == "Backlog")) |> Boards.delete_column()

      assert %{"error" => %{"message" => msg}} = prompt(ctx.conn, "triage", %{board: "flat1"})
      assert msg =~ "Flat has no intake list"
    end

    test "out of a scoped token's reach, refused; read-only token told so", ctx do
      conn = scoped(ctx.conn, ctx.user, scope_boards: [ctx.other.id])
      assert %{"error" => %{"message" => msg}} = prompt(conn, "triage", %{board: "deliv1"})
      assert msg =~ "scope"

      text =
        ctx.conn
        |> scoped(ctx.user, scope: "read")
        |> prompt("triage", %{board: "deliv1"})
        |> text!()

      assert text =~ "read-only"
    end
  end
end
