defmodule SlipdockWeb.MCP.WriteToolsTest do
  @moduledoc """
  The MCP write tools: each write lands and reads back through the HTTP API,
  a read-only token is refused before anything changes, nothing reaches a
  stranger's board, and a page edit on a stale hash is a conflict.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Wiki}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    roles = SlipdockWeb.APIGuide.list_roles(board.columns)
    card = card_fixture(roles.ready, %{"title" => "Existing"})
    tag_fixture(board, "ux")

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs"}, owner: stranger)
    secret = card_fixture(hd(theirs.columns), %{"title" => "Their card"})

    %{
      conn: conn,
      user: user,
      board: board,
      roles: roles,
      card: card,
      theirs: theirs,
      secret: secret
    }
  end

  defp call(conn, tool, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    result["structuredContent"]
  end

  defp error!(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  # The card as the HTTP API sees it: the point is that MCP writes are real.
  defp api_card(conn, id),
    do: conn |> get(~p"/api/cards/#{id}") |> json_response(200) |> Map.fetch!("card")

  defp read_only(conn, user) do
    {token, _} = Accounts.create_api_token(user, "reader", scope: "read")
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  test "tools/list marks writes as writes, and the overwriting ones as destructive", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1["annotations"]})

    for name <-
          ~w(create_card update_card move_card comment complete_card archive_card write_page) do
      assert tools[name]["readOnlyHint"] == false, name
    end

    assert tools["update_card"]["destructiveHint"] == true
    assert tools["write_page"]["destructiveHint"] == true
    assert tools["comment"]["destructiveHint"] == false
    # Restoring undoes it, so archiving overwrites nothing.
    assert tools["archive_card"]["destructiveHint"] == false
    # The deletes are the destructive ones; structure_tools_test.exs has them.
    for name <- Map.keys(tools), String.contains?(name, "delete") do
      assert tools[name]["destructiveHint"] == true, name
    end
  end

  describe "create_card" do
    test "lands in the ready list by default and reads back over the API", ctx do
      made =
        ctx.conn
        |> call("create_card", %{
          board: "delivery",
          title: "New work",
          description: "the brief",
          priority: "high",
          tags: ["ux"]
        })
        |> ok!()

      card = api_card(ctx.conn, made["id"])
      assert card["title"] == "New work"
      assert card["description"] == "the brief"
      assert card["priority"] == "high"
      assert card["tags"] == ["ux"]
      assert card["column_id"] == ctx.roles.ready.id
      assert made["url"] =~ "/boards/#{ctx.board.id}/cards/#{made["id"]}"
    end

    test "with a start date, and priority none", ctx do
      made =
        ctx.conn
        |> call("create_card", %{
          board: "delivery",
          title: "Scheduled",
          start_date: "2026-11-02",
          due_date: "2026-11-09",
          priority: "none"
        })
        |> ok!()

      card = api_card(ctx.conn, made["id"])
      assert card["start_date"] == "2026-11-02"
      assert card["due_date"] == "2026-11-09"
      assert card["priority"] == "none"
    end

    test "top puts it first in its list", ctx do
      made =
        ctx.conn |> call("create_card", %{board: "delivery", title: "Urgent", top: true}) |> ok!()

      [first | _] = Boards.list_cards(ctx.board, %{"column" => ctx.roles.ready.name})
      assert first.id == made["id"]
    end

    test "with parent: makes the sub-board, then adds to it", ctx do
      first = ctx.conn |> call("create_card", %{parent: ctx.card.id, title: "Step one"}) |> ok!()
      parent = Boards.get_card!(ctx.card.id)
      assert parent.sub_board
      assert first["board_id"] == parent.sub_board.id

      second = ctx.conn |> call("create_card", %{parent: ctx.card.id, title: "Step two"}) |> ok!()
      assert second["board_id"] == parent.sub_board.id
      assert api_card(ctx.conn, ctx.card.id)["sub_board"]["total"] == 2
    end

    test "an unknown sub-board template names the real ones", ctx do
      text =
        ctx.conn
        |> call("create_card", %{parent: ctx.card.id, title: "x", subcard_template: "Nope"})
        |> error!()

      assert text =~ "Simple"
      refute Boards.get_card!(ctx.card.id).sub_board
    end

    test "needs a board or a parent", ctx do
      assert ctx.conn |> call("create_card", %{title: "Floating"}) |> error!() =~
               "board, or parent"
    end

    test "an unknown tag is refused rather than dropped", ctx do
      assert ctx.conn
             |> call("create_card", %{board: "delivery", title: "x", tags: ["nope"]})
             |> error!() =~ "tag"
    end

    test "never on a stranger's board, nor under their card", ctx do
      assert ctx.conn |> call("create_card", %{board: "theirs", title: "Sneaky"}) |> error!() =~
               "no board"

      ctx.conn |> call("create_card", %{parent: ctx.secret.id, title: "Sneaky"}) |> error!()
      refute Enum.any?(Boards.list_cards(ctx.theirs, %{}), &(&1.title == "Sneaky"))
    end

    test "a read-only token is refused and nothing is made", ctx do
      text =
        ctx.conn
        |> read_only(ctx.user)
        |> call("create_card", %{board: "delivery", title: "Nope"})
        |> error!()

      assert text =~ "read-only"
      refute Enum.any?(Boards.list_cards(ctx.board, %{}), &(&1.title == "Nope"))
    end
  end

  describe "update_card" do
    test "fields, flags, tags and assignees", ctx do
      ctx.conn
      |> call("update_card", %{
        card: ctx.card.id,
        title: "Renamed",
        percent_complete: 40,
        add_flags: ["blocked"],
        add_tags: ["ux"],
        assignees: ["me"]
      })
      |> ok!()

      card = api_card(ctx.conn, ctx.card.id)
      assert card["title"] == "Renamed"
      assert card["percent_complete"] == 40
      assert card["flags"] == ["blocked"]
      assert card["tags"] == ["ux"]
      assert [%{"email" => email}] = card["assignees"]
      assert email == ctx.user.email

      ctx.conn
      |> call("update_card", %{card: ctx.card.id, remove_flags: ["blocked"], assignees: []})
      |> ok!()

      card = api_card(ctx.conn, ctx.card.id)
      assert card["flags"] == []
      assert card["assignees"] == []
    end

    test "priority goes back to none, and start_date sets and clears", ctx do
      ctx.conn
      |> call("update_card", %{card: ctx.card.id, priority: "high", start_date: "2026-11-02"})
      |> ok!()

      card = api_card(ctx.conn, ctx.card.id)
      assert card["priority"] == "high"
      assert card["start_date"] == "2026-11-02"

      ctx.conn
      |> call("update_card", %{card: ctx.card.id, priority: "none", start_date: ""})
      |> ok!()

      card = api_card(ctx.conn, ctx.card.id)
      assert card["priority"] == "none"
      assert card["start_date"] == nil
    end

    test "an unknown priority is refused", ctx do
      assert ctx.conn |> call("update_card", %{card: ctx.card.id, priority: "urgent"}) |> error!() =~
               "priority"

      assert Boards.get_card!(ctx.card.id).priority == "none"
    end

    test "add_blocked_by and remove_blocked_by; adding twice is not an error", ctx do
      blocker = card_fixture(ctx.roles.ready, %{"title" => "Schema"})

      result =
        ctx.conn
        |> call("update_card", %{card: ctx.card.id, add_blocked_by: [blocker.id]})
        |> ok!()

      assert result["blocked_by"] == [blocker.id]
      assert result["blocked"] == true

      ctx.conn
      |> call("update_card", %{card: ctx.card.id, add_blocked_by: ["##{blocker.id}"]})
      |> ok!()

      assert [%{"id" => id}] = api_card(ctx.conn, ctx.card.id)["blocked_by"]
      assert id == blocker.id

      ctx.conn
      |> call("update_card", %{card: ctx.card.id, remove_blocked_by: [blocker.id]})
      |> ok!()

      assert api_card(ctx.conn, ctx.card.id)["blocked_by"] == []
    end

    test "a blocker on a stranger's board is refused, and nothing else lands", ctx do
      ctx.conn
      |> call("update_card", %{
        card: ctx.card.id,
        title: "Renamed",
        add_blocked_by: [ctx.secret.id]
      })
      |> error!()

      card = Boards.get_card!(ctx.card.id)
      assert card.title == "Existing"
      assert card.blocked_by == []
    end

    test "a dependency that cannot be made rolls back the fields with it", ctx do
      text =
        ctx.conn
        |> call("update_card", %{
          card: ctx.card.id,
          title: "Renamed",
          add_blocked_by: [ctx.card.id]
        })
        |> error!()

      assert text =~ "itself"
      assert Boards.get_card!(ctx.card.id).title == "Existing"
    end

    test "an unknown blocker", ctx do
      assert ctx.conn
             |> call("update_card", %{card: ctx.card.id, add_blocked_by: [999_999]})
             |> error!() =~ "no card #999999"
    end

    test "checklist: add items, tick one, untick it; ticking twice stays ticked", ctx do
      ctx.conn
      |> call("update_card", %{card: ctx.card.id, add_checklist: ["Write it", "Test it"]})
      |> ok!()

      [first, second] = api_card(ctx.conn, ctx.card.id)["checklist"]["items"]
      assert {first["text"], second["text"]} == {"Write it", "Test it"}
      refute first["done"]

      for _ <- 1..2 do
        ctx.conn |> call("update_card", %{card: ctx.card.id, check_items: [first["id"]]}) |> ok!()
      end

      assert [%{"done" => true}, %{"done" => false}] =
               api_card(ctx.conn, ctx.card.id)["checklist"]["items"]

      ctx.conn
      |> call("update_card", %{card: ctx.card.id, uncheck_items: [first["id"], second["id"]]})
      |> ok!()

      assert [%{"done" => false}, %{"done" => false}] =
               api_card(ctx.conn, ctx.card.id)["checklist"]["items"]
    end

    test "a checklist item from another card is refused, and nothing is ticked", ctx do
      other = card_fixture(ctx.roles.ready, %{"title" => "Other"})
      {:ok, item} = Boards.add_checklist_item(other, "Not yours")

      text =
        ctx.conn
        |> call("update_card", %{card: ctx.card.id, check_items: [item.id]})
        |> error!()

      assert text =~ "not on card ##{ctx.card.id}"
      refute Repo.get!(Boards.ChecklistItem, item.id).done
    end

    test "ids that are not numbers", ctx do
      assert ctx.conn
             |> call("update_card", %{card: ctx.card.id, check_items: ["first"]})
             |> error!() =~ "check_items must be a list of numbers"
    end

    test "nothing to change is an error", ctx do
      assert ctx.conn |> call("update_card", %{card: ctx.card.id}) |> error!() =~
               "nothing to change"
    end

    test "a list that is not strings is an error", ctx do
      assert ctx.conn |> call("update_card", %{card: ctx.card.id, add_flags: [1]}) |> error!() =~
               "list of strings"
    end

    test "a stranger's card is left alone", ctx do
      ctx.conn |> call("update_card", %{card: ctx.secret.id, title: "Mine now"}) |> error!()
      assert Boards.get_card!(ctx.secret.id).title == "Their card"
    end

    test "a read-only token is refused", ctx do
      ctx.conn
      |> read_only(ctx.user)
      |> call("update_card", %{card: ctx.card.id, title: "No"})
      |> error!()

      assert Boards.get_card!(ctx.card.id).title == "Existing"
    end
  end

  describe "move_card" do
    test "to the doing list, at the top", ctx do
      other = card_fixture(ctx.roles.doing, %{"title" => "Already there"})
      ctx.conn |> call("move_card", %{card: ctx.card.id, column: ctx.roles.doing.name}) |> ok!()

      card = api_card(ctx.conn, ctx.card.id)
      assert card["column_id"] == ctx.roles.doing.id
      assert card["position"] < Boards.get_card!(other.id).position
    end

    test "an unknown list", ctx do
      assert ctx.conn |> call("move_card", %{card: ctx.card.id, column: "Nowhere"}) |> error!() =~
               "Nowhere"
    end

    test "to another board, at the bottom of the list named", ctx do
      elsewhere = board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere"}, owner: ctx.user)
      target = List.last(elsewhere.columns)

      moved =
        ctx.conn
        |> call("move_card", %{card: ctx.card.id, board: "elsewhere", column: target.name})
        |> ok!()

      assert moved["board_id"] == elsewhere.id
      card = api_card(ctx.conn, ctx.card.id)
      assert card["board_id"] == elsewhere.id
      assert card["column_id"] == target.id
    end

    test "never onto a stranger's board", ctx do
      assert ctx.conn |> call("move_card", %{card: ctx.card.id, board: "theirs"}) |> error!() =~
               "no board"

      assert Boards.get_card!(ctx.card.id).board_id == ctx.board.id
    end

    test "an archived card is not moved to another board", ctx do
      board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere"}, owner: ctx.user)
      {:ok, _} = Boards.archive_card(ctx.card)

      assert ctx.conn |> call("move_card", %{card: ctx.card.id, board: "elsewhere"}) |> error!() =~
               "Restore"

      assert Boards.get_card!(ctx.card.id).board_id == ctx.board.id
    end

    test "a bad position", ctx do
      assert ctx.conn |> call("move_card", %{card: ctx.card.id, position: "middle"}) |> error!() =~
               "top or bottom"
    end
  end

  describe "comment" do
    test "lands on the card", ctx do
      result = ctx.conn |> call("comment", %{card: ctx.card.id, body: "Picked up."}) |> ok!()
      assert result["comment"]["body"] == "Picked up."
      assert [%{"body" => "Picked up."}] = api_card(ctx.conn, ctx.card.id)["comments"]
    end

    test "a blank comment is refused", ctx do
      assert ctx.conn |> call("comment", %{card: ctx.card.id, body: "  "}) |> error!() ==
               "body is required"
    end

    test "not on a stranger's card", ctx do
      ctx.conn |> call("comment", %{card: ctx.secret.id, body: "hi"}) |> error!()
      assert Repo.preload(Boards.get_card!(ctx.secret.id), :comments).comments == []
    end
  end

  describe "archive_card" do
    test "archives it out of listings, and restore brings it back", ctx do
      result = ctx.conn |> call("archive_card", %{card: ctx.card.id}) |> ok!()
      assert result["archived"] == true
      assert api_card(ctx.conn, ctx.card.id)["archived_at"]
      refute Enum.any?(Boards.list_cards(ctx.board, %{}), &(&1.id == ctx.card.id))

      result = ctx.conn |> call("archive_card", %{card: ctx.card.id, restore: true}) |> ok!()
      refute Map.has_key?(result, "archived")
      assert api_card(ctx.conn, ctx.card.id)["archived_at"] == nil
      assert Enum.any?(Boards.list_cards(ctx.board, %{}), &(&1.id == ctx.card.id))
    end

    test "asking for what is already so leaves it as it is", ctx do
      ctx.conn |> call("archive_card", %{card: ctx.card.id, restore: true}) |> ok!()
      assert Boards.get_card!(ctx.card.id).archived_at == nil

      ctx.conn |> call("archive_card", %{card: ctx.card.id}) |> ok!()
      stamp = Boards.get_card!(ctx.card.id).archived_at
      ctx.conn |> call("archive_card", %{card: ctx.card.id}) |> ok!()
      assert Boards.get_card!(ctx.card.id).archived_at == stamp
    end

    test "restore must be true or false", ctx do
      assert ctx.conn |> call("archive_card", %{card: ctx.card.id, restore: "yes"}) |> error!() =~
               "restore must be true or false"
    end

    test "not a stranger's card", ctx do
      ctx.conn |> call("archive_card", %{card: ctx.secret.id}) |> error!()
      assert Boards.get_card!(ctx.secret.id).archived_at == nil
    end

    test "a read-only token cannot", ctx do
      assert ctx.conn
             |> read_only(ctx.user)
             |> call("archive_card", %{card: ctx.card.id})
             |> error!() =~
               "read-only"

      assert Boards.get_card!(ctx.card.id).archived_at == nil
    end
  end

  describe "complete_card" do
    test "marks it completed, moves it to the done list, and leaves the note", ctx do
      ctx.conn
      |> call("complete_card", %{card: ctx.card.id, comment: "Done: shipped it."})
      |> ok!()

      card = api_card(ctx.conn, ctx.card.id)
      assert card["completed"] == true
      assert card["column_id"] == ctx.roles.done.id
      assert [%{"body" => "Done: shipped it."}] = card["comments"]
    end

    test "a read-only token cannot", ctx do
      ctx.conn |> read_only(ctx.user) |> call("complete_card", %{card: ctx.card.id}) |> error!()
      refute Boards.get_card!(ctx.card.id).completed
    end
  end

  describe "write_page" do
    test "create, then append, recorded as made over MCP by the token's client", ctx do
      made =
        ctx.conn
        |> call("write_page", %{
          mode: "create",
          board: "delivery",
          title: "Runbook",
          body: "# Deploy\n\nStep one."
        })
        |> ok!()

      assert made["code"] =~ "W-"

      ctx.conn
      |> call("write_page", %{mode: "append", page: made["code"], body: "Step two."})
      |> ok!()

      page = Wiki.get_page!(made["id"])
      assert page.body =~ "Step one."
      assert page.body =~ "Step two."

      revision =
        page
        |> Repo.preload(:revisions)
        |> Map.fetch!(:revisions)
        |> Enum.max_by(& &1.id)

      assert revision.via == "mcp"
      assert revision.agent == "test"
    end

    test "sections: append needs no hash, replace does", ctx do
      page =
        page_fixture(ctx.board, %{
          "title" => "Ops",
          "body" => "# Deploy\n\nOld.\n\n# Rollback\n\nUndo."
        })

      ctx.conn
      |> call("write_page", %{
        mode: "append_section",
        page: page.code,
        section: "Deploy",
        body: "Also this."
      })
      |> ok!()

      assert Wiki.get_page!(page.id).body =~ "Also this."

      assert ctx.conn
             |> call("write_page", %{
               mode: "replace_section",
               page: page.code,
               section: "Deploy",
               body: "# Deploy\n\nNew."
             })
             |> error!() == "base_hash is required"

      hash = Wiki.get_page!(page.id).content_hash

      ctx.conn
      |> call("write_page", %{
        mode: "replace_section",
        page: page.code,
        section: "Deploy",
        body: "# Deploy\n\nNew.",
        base_hash: hash
      })
      |> ok!()

      body = Wiki.get_page!(page.id).body
      assert body =~ "New."
      refute body =~ "Old."
      assert body =~ "Undo."
    end

    test "a stale base_hash is a conflict, and nothing is overwritten", ctx do
      page = page_fixture(ctx.board, %{"title" => "Spec", "body" => "first"})
      stale = page.content_hash
      {:ok, _} = Wiki.update_page(page, %{"body" => "someone else's edit"}, user: ctx.user)

      text =
        ctx.conn
        |> call("write_page", %{mode: "replace", page: page.code, body: "mine", base_hash: stale})
        |> error!()

      assert text =~ "conflict"
      assert text =~ Wiki.get_page!(page.id).content_hash
      assert Wiki.get_page!(page.id).body == "someone else's edit"
    end

    test "an unknown mode", ctx do
      assert ctx.conn |> call("write_page", %{mode: "delete", page: "W-1", body: ""}) |> error!() =~
               "mode must be"
    end

    test "not on a stranger's board", ctx do
      ctx.conn
      |> call("write_page", %{mode: "create", board: "theirs", title: "Sneaky", body: "x"})
      |> error!()

      their_page =
        page_fixture(ctx.theirs, %{"title" => "Theirs", "body" => "theirs"},
          user: Accounts.get_user!(ctx.theirs.owner_id)
        )

      ctx.conn
      |> call("write_page", %{mode: "append", page: their_page.code, body: "graffiti"})
      |> error!()

      assert Wiki.get_page!(their_page.id).body == "theirs"
    end

    test "a read-only token cannot write", ctx do
      text =
        ctx.conn
        |> read_only(ctx.user)
        |> call("write_page", %{mode: "create", board: "delivery", title: "Nope", body: "x"})
        |> error!()

      assert text =~ "read-only"
    end
  end
end

defmodule SlipdockWeb.MCP.WriteToolsLimitTest do
  @moduledoc "An account at its limit: the tool error says stop, not try again."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Settings}

  setup %{user: user} do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

    board = board_fixture(%{"name" => "Full", "code" => "full"}, owner: user)
    {:ok, _} = Boards.create_card(hd(board.columns), %{"title" => "The only one"})
    %{board: board}
  end

  test "card_limit_reached comes back as a tool error that says not to retry", %{
    conn: conn,
    board: board
  } do
    result =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "create_card", arguments: %{board: "full", title: "One too many"}}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    assert text =~ "card_limit_reached"
    assert text =~ "Don't retry"
    assert length(Boards.list_cards(board, %{})) == 1
  end
end
