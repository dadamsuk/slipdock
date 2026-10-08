defmodule SlipdockWeb.MCP.ReadToolsTest do
  @moduledoc """
  The read-only MCP tools: each returns what the API would, nothing another
  tenant owns is visible, a token's board scope narrows them as it narrows the
  API, and bad arguments come back as tool errors (`isError`), never crashes.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    [first, second | _] = board.columns

    top = card_fixture(first, %{"title" => "Top of the list", "description" => "what it is for"})
    done = card_fixture(first, %{"title" => "Already done", "completed" => true})
    blocker = card_fixture(second, %{"title" => "Blocker"})
    blocked = card_fixture(first, %{"title" => "Waiting on the blocker"})
    {:ok, _} = Boards.add_dependency(blocked, blocker)
    {:ok, _} = Boards.add_comment(top, "the real constraint is here")

    other = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Private", "code" => "private"}, owner: other)
    secret = card_fixture(hd(theirs.columns), %{"title" => "Their secret"})

    %{
      conn: conn,
      user: user,
      board: board,
      first: first,
      second: second,
      top: top,
      done: done,
      blocked: blocked,
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

  defp scoped(conn, user, opts) do
    {token, _} = Accounts.create_api_token(user, "scoped", opts)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  test "tools/list offers every read tool, all read-only", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    names = Enum.map(tools, & &1["name"])

    for name <- ~w(get_guide list_boards get_board list_cards get_card search read_page activity) do
      tool = Enum.find(tools, &(&1["name"] == name))
      assert tool, "#{name} missing from #{inspect(names)}"
      assert tool["annotations"]["readOnlyHint"] == true
      assert String.length(tool["description"]) < 250
    end
  end

  describe "list_boards" do
    test "lists the caller's boards with their lists and roles, not a stranger's", ctx do
      %{"boards" => boards} = ctx.conn |> call("list_boards", %{}) |> ok!()

      assert [delivery] = Enum.filter(boards, &(&1["code"] == "delivery"))
      refute Enum.any?(boards, &(&1["code"] == "private"))
      assert delivery["owner"] == "yours"
      assert Enum.map(delivery["lists"], & &1["name"]) == Enum.map(ctx.board.columns, & &1.name)

      roles = SlipdockWeb.APIGuide.list_roles(ctx.board.columns)
      assert delivery["ready"] == (roles.ready && roles.ready.name)
      assert delivery["done"] == (roles.done && roles.done.name)
    end

    test "a token scoped to another board does not list this one", ctx do
      other = board_fixture(%{"name" => "Other", "code" => "other"}, owner: ctx.user)
      conn = scoped(ctx.conn, ctx.user, scope_boards: [other.id])

      %{"boards" => boards} = conn |> call("list_boards", %{}) |> ok!()
      assert Enum.map(boards, & &1["code"]) == ["other"]
    end

    test "archived must be a boolean", ctx do
      assert ctx.conn |> call("list_boards", %{archived: "yes"}) |> error!() =~ "true or false"
    end
  end

  describe "get_board" do
    test "by code: lists in order with a line per card", ctx do
      board = ctx.conn |> call("get_board", %{board: "delivery"}) |> ok!()

      assert board["id"] == ctx.board.id
      first = Enum.find(board["lists"], &(&1["name"] == ctx.first.name))
      titles = Enum.map(first["cards"], & &1["title"])
      assert "Top of the list" in titles

      line = Enum.find(first["cards"], &(&1["id"] == ctx.blocked.id))
      assert line["blocked"] == true
      refute Map.has_key?(line, "comments")
      refute Map.has_key?(line, "checklist")
    end

    test "each card carries its description, null when it has none", ctx do
      board = ctx.conn |> call("get_board", %{board: "delivery"}) |> ok!()
      lines = board["lists"] |> Enum.flat_map(& &1["cards"]) |> Map.new(&{&1["id"], &1})

      assert lines[ctx.top.id]["description"] == "what it is for"
      assert Map.has_key?(lines[ctx.blocked.id], "description")
      assert lines[ctx.blocked.id]["description"] == nil
    end

    test "another tenant's board reads as not there", ctx do
      text = ctx.conn |> call("get_board", %{board: "private"}) |> error!()
      assert text =~ "no board you can see"
      refute text =~ "Private"

      assert ctx.conn |> call("get_board", %{board: to_string(ctx.theirs.id)}) |> error!() =~
               "no board"
    end

    test "board is required", ctx do
      assert ctx.conn |> call("get_board", %{}) |> error!() == "board is required"
    end
  end

  describe "list_cards" do
    test "filters the way the CLI does: column, open, deps ready", ctx do
      %{"cards" => cards} =
        ctx.conn
        |> call("list_cards", %{
          board: "delivery",
          column: ctx.first.name,
          open: true,
          deps: "ready"
        })
        |> ok!()

      ids = Enum.map(cards, & &1["id"])
      assert ctx.top.id in ids
      refute ctx.done.id in ids
      refute ctx.blocked.id in ids
    end

    test "each card carries its description, null when it has none", ctx do
      %{"cards" => cards} = ctx.conn |> call("list_cards", %{board: "delivery"}) |> ok!()
      lines = Map.new(cards, &{&1["id"], &1})

      assert lines[ctx.top.id]["description"] == "what it is for"
      assert Map.has_key?(lines[ctx.done.id], "description")
      assert lines[ctx.done.id]["description"] == nil
    end

    test "open: false gives the completed ones", ctx do
      %{"cards" => cards} =
        ctx.conn |> call("list_cards", %{board: "delivery", open: false}) |> ok!()

      assert Enum.map(cards, & &1["id"]) == [ctx.done.id]
    end

    test "limit truncates and says so", ctx do
      result = ctx.conn |> call("list_cards", %{board: "delivery", limit: 1}) |> ok!()
      assert length(result["cards"]) == 1
      assert result["truncated"] == true
      assert result["total"] == 4
    end

    test "assignee me and no_assignee", ctx do
      {:ok, _} = Boards.update_card(ctx.top, %{"assignee_id" => ctx.user.id})

      %{"cards" => mine} =
        ctx.conn |> call("list_cards", %{board: "delivery", assignee: "me"}) |> ok!()

      assert Enum.map(mine, & &1["id"]) == [ctx.top.id]

      %{"cards" => nobody} =
        ctx.conn |> call("list_cards", %{board: "delivery", no_assignee: true}) |> ok!()

      refute ctx.top.id in Enum.map(nobody, & &1["id"])
      assert length(nobody) == 3
    end

    test "archived: left out by default, included, or alone", ctx do
      {:ok, _} = Boards.archive_card(ctx.done)
      ids = fn args -> ctx.conn |> call("list_cards", args) |> ok!() |> Map.fetch!("cards") end

      default = ids.(%{board: "delivery"})
      refute ctx.done.id in Enum.map(default, & &1["id"])

      assert Enum.map(ids.(%{board: "delivery", archived: "exclude"}), & &1["id"]) ==
               Enum.map(default, & &1["id"])

      included = ids.(%{board: "delivery", archived: "include"})
      assert length(included) == length(default) + 1
      assert %{"archived" => true} = Enum.find(included, &(&1["id"] == ctx.done.id))

      refute Enum.any?(
               included -- [Enum.find(included, &(&1["id"] == ctx.done.id))],
               & &1["archived"]
             )

      assert [%{"id" => id}] = ids.(%{board: "delivery", archived: "only"})
      assert id == ctx.done.id
    end

    test "an unknown archived value is an error", ctx do
      assert ctx.conn |> call("list_cards", %{board: "delivery", archived: "yes"}) |> error!() =~
               "archived must be one of"
    end

    test "an unknown deps bucket is an error, not everything", ctx do
      text = ctx.conn |> call("list_cards", %{board: "delivery", deps: "soon"}) |> error!()
      assert text =~ "deps must be one of"
    end

    test "a bad limit is an error", ctx do
      assert ctx.conn |> call("list_cards", %{board: "delivery", limit: -1}) |> error!() =~
               "limit"
    end

    test "a stranger's board is not listable", ctx do
      assert ctx.conn |> call("list_cards", %{board: "private"}) |> error!() =~ "no board"
    end
  end

  describe "list_cards full" do
    setup ctx do
      {:ok, _} = Boards.add_checklist_item(ctx.top, "write the tests")
      {:ok, _} = Boards.add_checklist_item(ctx.top, "ship it")
      page = page_fixture(ctx.board, %{"title" => "Spec", "body" => "About ##{ctx.top.id}."})
      %{page: page}
    end

    defp full(conn, args),
      do: conn |> call("list_cards", Map.merge(%{board: "delivery", full: true}, args)) |> ok!()

    test "each card is what get_card returns: comments, checklist, docs, url", ctx do
      %{"cards" => cards} = full(ctx.conn, %{})
      top = Enum.find(cards, &(&1["id"] == ctx.top.id))

      assert [%{"body" => "the real constraint is here"}] = top["comments"]
      assert %{"done" => 0, "total" => 2, "items" => items} = top["checklist"]
      assert Enum.map(items, & &1["text"]) == ["write the tests", "ship it"]
      assert [%{"code" => code, "title" => "Spec"}] = top["docs"]
      assert code == ctx.page.code
      assert top["url"] == "http://www.example.com/boards/#{ctx.board.id}/cards/#{ctx.top.id}"

      assert top == ctx.conn |> call("get_card", %{card: ctx.top.id}) |> ok!()

      blocked = Enum.find(cards, &(&1["id"] == ctx.blocked.id))
      assert [%{"title" => "Blocker"}] = blocked["blocked_by"]
      assert blocked["docs"] == []
      assert blocked["comments"] == []
    end

    test "full false, or left out, is the one-line listing", ctx do
      for args <- [%{board: "delivery"}, %{board: "delivery", full: false}] do
        %{"cards" => cards} = ctx.conn |> call("list_cards", args) |> ok!()
        top = Enum.find(cards, &(&1["id"] == ctx.top.id))
        refute Map.has_key?(top, "comments")
        refute Map.has_key?(top, "checklist")
        refute Map.has_key?(top, "docs")
      end
    end

    test "filters still apply, archived included", ctx do
      {:ok, _} = Boards.archive_card(ctx.done)

      refute ctx.done.id in Enum.map(full(ctx.conn, %{})["cards"], & &1["id"])

      assert [%{"id" => id, "archived_at" => archived_at}] =
               full(ctx.conn, %{archived: "only"})["cards"]

      assert id == ctx.done.id
      assert archived_at

      assert Enum.map(full(ctx.conn, %{q: "constraint"})["cards"], & &1["id"]) == []
      assert Enum.map(full(ctx.conn, %{q: "what it is"})["cards"], & &1["id"]) == [ctx.top.id]
    end

    test "limit truncates and says so; the default is smaller than for lines", ctx do
      result = full(ctx.conn, %{limit: 1})
      assert length(result["cards"]) == 1
      assert result["truncated"] == true
      assert result["total"] == 4

      for n <- 1..25, do: card_fixture(ctx.second, %{"title" => "Filler #{n}"})

      result = full(ctx.conn, %{})
      assert length(result["cards"]) == 20
      assert result["truncated"] == true
      assert result["total"] == 29

      assert length(
               ctx.conn
               |> call("list_cards", %{board: "delivery"})
               |> ok!()
               |> Map.fetch!("cards")
             ) ==
               29
    end

    test "formula scores match get_card's, computed across the board", ctx do
      {:ok, value} =
        Slipdock.Fields.create_field(ctx.board, %{"name" => "Value", "kind" => "rating"})

      {:ok, _} =
        Slipdock.Fields.create_field(ctx.board, %{
          "name" => "Score",
          "kind" => "formula",
          "config" => %{"mode" => "weighted", "weights" => [%{"key" => "value", "weight" => 1}]}
        })

      {:ok, _} = Slipdock.Fields.set_value(ctx.top, value, 5)
      {:ok, _} = Slipdock.Fields.set_value(ctx.blocked, value, 1)

      # Only the top card listed: its score is still normalised against the
      # blocked one, as get_card does it.
      assert [top] = full(ctx.conn, %{q: "what it is"})["cards"]

      assert top["scores"] ==
               ctx.conn |> call("get_card", %{card: ctx.top.id}) |> ok!() |> Map.fetch!("scores")

      assert_in_delta top["scores"]["score"], 100.0, 0.01
    end

    test "a stranger's page about the card is not among its docs", ctx do
      stranger = Accounts.get_user!(ctx.theirs.owner_id)

      page_fixture(ctx.theirs, %{"title" => "Their notes", "body" => "##{ctx.top.id}"},
        user: stranger
      )

      top = Enum.find(full(ctx.conn, %{})["cards"], &(&1["id"] == ctx.top.id))
      assert Enum.map(top["docs"], & &1["title"]) == ["Spec"]
    end

    test "a stranger's board is refused, and so is a board outside the token's scope", ctx do
      assert ctx.conn |> call("list_cards", %{board: "private", full: true}) |> error!() =~
               "no board"

      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)
      conn = scoped(ctx.conn, ctx.user, scope_boards: [other.id])
      assert conn |> call("list_cards", %{board: "delivery", full: true}) |> error!() =~ "scope"
    end

    test "a dependency on a card the caller can't read stays hidden", ctx do
      {:ok, _} = Boards.add_dependency(ctx.top, ctx.secret)

      top = Enum.find(full(ctx.conn, %{})["cards"], &(&1["id"] == ctx.top.id))
      assert [%{"title" => "A card you can't see"}] = top["blocked_by"]
      refute inspect(top) =~ "Their secret"
    end

    test "full must be a boolean", ctx do
      assert ctx.conn |> call("list_cards", %{board: "delivery", full: "yes"}) |> error!() =~
               "true or false"
    end
  end

  describe "activity" do
    test "the board's log, newest first, as the API gives it", ctx do
      result = ctx.conn |> call("activity", %{board: "delivery"}) |> ok!()

      assert result["board"]["code"] == "delivery"
      messages = Enum.map(result["activity"], & &1["message"])
      assert Enum.any?(messages, &(&1 =~ "Top of the list"))
      assert Enum.any?(messages, &(&1 =~ "Waiting on the blocker"))
      # Newest first: the last card made comes before the first.
      newest = Enum.find_index(messages, &(&1 =~ "Waiting on the blocker"))
      oldest = Enum.find_index(messages, &(&1 =~ "Already done"))
      assert newest < oldest

      assert %{"id" => _, "kind" => _, "card_id" => _, "at" => _} = hd(result["activity"])
      refute inspect(result) =~ "Their secret"
    end

    test "limit caps how many", ctx do
      assert %{"activity" => [_]} =
               ctx.conn |> call("activity", %{board: ctx.board.id, limit: 1}) |> ok!()
    end

    test "card narrows it to the entries about that card", ctx do
      %{"activity" => entries} =
        ctx.conn |> call("activity", %{board: "delivery", card: "##{ctx.top.id}"}) |> ok!()

      assert entries != []
      assert Enum.all?(entries, &(&1["card_id"] == ctx.top.id))
    end

    test "a card with no entries on this board gives none", ctx do
      assert %{"activity" => []} =
               ctx.conn |> call("activity", %{board: "delivery", card: ctx.secret.id}) |> ok!()
    end

    test "an unknown board and a stranger's board read the same", ctx do
      assert ctx.conn |> call("activity", %{board: "nowhere"}) |> error!() =~ "no board"
      assert ctx.conn |> call("activity", %{board: "private"}) |> error!() =~ "no board"
    end

    test "a board outside the token's scope is refused", ctx do
      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)
      conn = scoped(ctx.conn, ctx.user, scope_boards: [other.id])
      assert conn |> call("activity", %{board: "delivery"}) |> error!() =~ "scope"
    end

    test "a read-only token may read it", ctx do
      conn = scoped(ctx.conn, ctx.user, scope: "read")
      assert %{"activity" => [_ | _]} = conn |> call("activity", %{board: "delivery"}) |> ok!()
    end

    test "bad arguments are tool errors", ctx do
      assert ctx.conn |> call("activity", %{}) |> error!() =~ "board is required"

      assert ctx.conn |> call("activity", %{board: "delivery", limit: 0}) |> error!() =~
               "positive whole number"

      assert ctx.conn |> call("activity", %{board: "delivery", card: "top"}) |> error!() =~
               "card number"
    end
  end

  describe "get_card" do
    test "the whole card: description, comments, dependencies", ctx do
      card = ctx.conn |> call("get_card", %{card: ctx.top.id}) |> ok!()

      assert card["title"] == "Top of the list"
      assert [%{"body" => "the real constraint is here"}] = card["comments"]
      assert card["docs"] == []
      assert card["url"] == "http://www.example.com/boards/#{ctx.board.id}/cards/#{ctx.top.id}"

      blocked = ctx.conn |> call("get_card", %{card: "##{ctx.blocked.id}"}) |> ok!()
      assert [%{"title" => "Blocker"}] = blocked["blocked_by"]
    end

    test "another tenant's card reads as not there", ctx do
      text = ctx.conn |> call("get_card", %{card: ctx.secret.id}) |> error!()
      refute text =~ "Their secret"
      assert text =~ "can't" or text =~ "don't" or text =~ "no card"
    end

    test "a card that does not exist", ctx do
      assert ctx.conn |> call("get_card", %{card: 999_999_999}) |> error!() =~ "no card"
    end

    test "a card number that is not a number", ctx do
      assert ctx.conn |> call("get_card", %{card: "the top one"}) |> error!() =~ "card number"
    end

    test "a scoped token cannot read a card on a board outside its scope", ctx do
      other = board_fixture(%{"name" => "Other"}, owner: ctx.user)
      conn = scoped(ctx.conn, ctx.user, scope_boards: [other.id])

      assert conn |> call("get_card", %{card: ctx.top.id}) |> error!() =~ "scope"
    end
  end

  describe "read_page" do
    setup ctx do
      page =
        page_fixture(ctx.board, %{"title" => "Runbook", "body" => "# Steps\n\nDo the thing."})

      draft =
        page_fixture(ctx.theirs, %{"title" => "Theirs", "body" => "secret"},
          user: Accounts.get_user!(ctx.theirs.owner_id)
        )

      %{page: page, their_page: draft}
    end

    test "by code: the Markdown and its content hash", ctx do
      page = ctx.conn |> call("read_page", %{page: ctx.page.code}) |> ok!()

      assert page["title"] == "Runbook"
      assert page["body"] =~ "Do the thing."
      assert page["content_hash"]
      assert page["truncated"] == false
    end

    test "by title on a board", ctx do
      page = ctx.conn |> call("read_page", %{page: "Runbook", board: "delivery"}) |> ok!()
      assert page["code"] == ctx.page.code
    end

    test "another tenant's page reads as not there", ctx do
      text = ctx.conn |> call("read_page", %{page: ctx.their_page.code}) |> error!()
      refute text =~ "secret"
    end

    test "a page nobody wrote", ctx do
      assert ctx.conn |> call("read_page", %{page: "W-99999"}) |> error!() =~ "no page"
    end

    test "a draft is invisible to a reader who cannot edit", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")
      draft = page_fixture(ctx.board, %{"title" => "Half", "status" => "draft"})

      assert conn_as(reader) |> call("read_page", %{page: draft.code}) |> error!() =~ "no page"
      assert ctx.conn |> call("read_page", %{page: draft.code}) |> ok!()
    end
  end

  describe "get_guide" do
    test "by default gives the short guide, small enough for one tool result", ctx do
      %{"guide" => guide} = ctx.conn |> call("get_guide", %{}) |> ok!()
      served = ctx.conn |> get(~p"/api/guide") |> response(200)

      assert byte_size(guide) < 22_000
      assert byte_size(served) > 2 * byte_size(guide)

      for heading <- [
            "Over MCP",
            "Epics and subcards",
            "Choosing what to do next",
            "Working a card",
            "Your boards right now"
          ] do
        assert guide =~ "\n## #{heading}\n", "#{heading} missing from the short guide"
      end

      # The reader's own boards are in it, and the rest is named, not included.
      assert guide =~ "`delivery`"
      assert guide =~ "- `automations` — Automations and alerts"
      assert guide =~ "- `model` — The model"
      refute guide =~ "\n## Automations and alerts\n"
      refute guide =~ "\n## Every endpoint\n"
    end

    test "section gives that section alone", ctx do
      %{"guide" => text} = ctx.conn |> call("get_guide", %{section: "automations"}) |> ok!()

      assert text =~ ~r/\A## Automations and alerts\n/
      refute text =~ "\n## Runners\n"
      refute text =~ "Slipdock for agents"

      # The part of Getting in about MCP is a section of its own.
      %{"guide" => mcp} = ctx.conn |> call("get_guide", %{section: "MCP"}) |> ok!()
      assert mcp =~ ~r/\A## Over MCP\n/
      refute mcp =~ "The AI key"
    end

    test "section all is the whole guide /api/guide serves", ctx do
      %{"guide" => guide} = ctx.conn |> call("get_guide", %{section: "all"}) |> ok!()
      assert guide == ctx.conn |> get(~p"/api/guide") |> response(200)
    end

    test "an unknown section is an error naming the ones there are", ctx do
      text = ctx.conn |> call("get_guide", %{section: "nope"}) |> error!()

      assert text =~ ~s(no section "nope")

      for key <- ~w(model epics automations wiki recipes endpoints mcp all),
          do: assert(text =~ key)
    end

    test "section must be a string", ctx do
      assert ctx.conn |> call("get_guide", %{section: 3.5}) |> error!() =~
               "section must be a string"
    end

    test "every section has its own name, and they cover the whole guide" do
      sections = SlipdockWeb.APIGuide.sections(base_url: "https://x")
      keys = Enum.map(sections, &elem(&1, 0))

      assert keys == Enum.uniq(keys)
      assert Enum.all?(keys, &(&1 =~ ~r/\A[a-z0-9-]+\z/))

      whole = sections |> Enum.reject(&(elem(&1, 0) == "mcp")) |> Enum.map_join(&elem(&1, 2))
      assert whole == SlipdockWeb.APIGuide.markdown(base_url: "https://x")
    end
  end

  test "get_guide offers section in its input schema", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    tool = Enum.find(tools, &(&1["name"] == "get_guide"))
    assert tool["inputSchema"]["properties"]["section"]["type"] == "string"
    refute Map.has_key?(tool["inputSchema"], "required")
  end

  test "a mistyped argument is a tool error, not a crash", ctx do
    # A map where a string belongs: a client need not check the schema.
    text = ctx.conn |> call("get_board", %{board: %{"id" => 1}}) |> error!()
    assert text =~ "board must be a string"
  end

  defmodule Crashes do
    @behaviour SlipdockWeb.MCP.Tool
    def name, do: "crashes"
    def title, do: "Crashes"
    def description, do: "Always raises."
    def input_schema, do: %{type: "object"}
    def read_only?, do: true
    def call(_args, _context), do: raise("boom")
  end

  defmodule Writes do
    @behaviour SlipdockWeb.MCP.Tool
    def name, do: "writes"
    def title, do: "Writes"
    def description, do: "Pretends to write."
    def input_schema, do: %{type: "object"}
    def read_only?, do: false
    def call(_args, _context), do: {:ok, %{wrote: true}}
  end

  describe "SlipdockWeb.MCP.Tools.call/3" do
    @describetag capture_log: true

    test "a tool that raises comes back as an error result", ctx do
      context = %{user: ctx.user, token: %{scope: "write"}, base_url: ""}

      assert {:error, message} = SlipdockWeb.MCP.Tools.call(Crashes, %{}, context)
      assert message =~ "crashes failed"
      refute message =~ "boom"
    end

    test "a write tool refuses a read-only token without running", ctx do
      read = %{user: ctx.user, token: %{scope: "read"}, base_url: ""}
      write = %{user: ctx.user, token: %{scope: "write"}, base_url: ""}

      assert {:error, message} = SlipdockWeb.MCP.Tools.call(Writes, %{}, read)
      assert message =~ "read-only"
      assert message =~ "Don't retry"
      assert {:ok, %{wrote: true}} = SlipdockWeb.MCP.Tools.call(Writes, %{}, write)
    end
  end
end
