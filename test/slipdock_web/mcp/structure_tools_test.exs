defmodule SlipdockWeb.MCP.StructureToolsTest do
  @moduledoc """
  The MCP tools that make and remove things rather than edit them: deleting a
  card, adding and deleting lists, and making, archiving and deleting boards.
  Each lands for real, nothing that cannot be undone happens without being
  asked for twice, owner-only acts stay owner-only, and nothing reaches a
  stranger's board.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    roles = SlipdockWeb.APIGuide.list_roles(board.columns)
    card = card_fixture(roles.ready, %{"title" => "Existing"})

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs"}, owner: stranger)
    secret = card_fixture(hd(theirs.columns), %{"title" => "Their card"})

    shared = board_fixture(%{"name" => "Shared", "code" => "shared"}, owner: stranger)
    share_fixture(shared, user, "write")

    %{
      conn: conn,
      user: user,
      board: board,
      roles: roles,
      card: card,
      theirs: theirs,
      secret: secret,
      shared: shared
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

  defp with_token(conn, user, opts) do
    {token, _} = Accounts.create_api_token(user, "limited", opts)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp list_names(board),
    do: board.id |> Boards.get_board!() |> Map.fetch!(:columns) |> Enum.map(& &1.name)

  test "tools/list marks the deletes destructive, and the rest as plain writes", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    for name <- ~w(delete_card delete_list delete_board) do
      assert tools[name]["annotations"]["destructiveHint"] == true, name
    end

    for name <- ~w(create_list create_board archive_board) do
      assert tools[name]["annotations"]["readOnlyHint"] == false, name
      assert tools[name]["annotations"]["destructiveHint"] == false, name
    end

    for name <- ~w(delete_card create_list delete_list create_board archive_board delete_board) do
      assert String.length(tools[name]["description"]) < 250, name
    end
  end

  describe "delete_card" do
    test "with confirm, it is gone for good", ctx do
      result = ctx.conn |> call("delete_card", %{card: ctx.card.id, confirm: true}) |> ok!()
      assert result["deleted"] == true
      assert result["card"] == ctx.card.id
      assert Boards.get_card(ctx.card.id) == nil
      assert ctx.conn |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(404)
    end

    test "takes its subcards with it", ctx do
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.card, t)
      child = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Child"})

      ctx.conn |> call("delete_card", %{card: ctx.card.id, confirm: true}) |> ok!()
      assert Boards.get_card(child.id) == nil
      assert Boards.get_board(sub.id) == nil
    end

    test "without confirm = true nothing happens, and archive_card is named", ctx do
      for args <- [
            %{card: ctx.card.id},
            %{card: ctx.card.id, confirm: false},
            %{card: ctx.card.id, confirm: "yes"}
          ] do
        text = ctx.conn |> call("delete_card", args) |> error!()
        assert text =~ "confirm = true"
        assert text =~ "archive_card"
      end

      assert Boards.get_card(ctx.card.id)
    end

    test "not a stranger's card", ctx do
      assert ctx.conn |> call("delete_card", %{card: ctx.secret.id, confirm: true}) |> error!() =~
               "you don't edit this card"

      assert Boards.get_card(ctx.secret.id)
    end

    test "an unknown card", ctx do
      assert ctx.conn |> call("delete_card", %{card: 999_999, confirm: true}) |> error!() =~
               "no card"
    end

    test "a read-only token cannot", ctx do
      assert ctx.conn
             |> with_token(ctx.user, scope: "read")
             |> call("delete_card", %{card: ctx.card.id, confirm: true})
             |> error!() =~ "read-only"

      assert Boards.get_card(ctx.card.id)
    end
  end

  describe "create_list" do
    test "adds a list at the end, with its category", ctx do
      result =
        ctx.conn
        |> call("create_list", %{
          board: "delivery",
          name: "Review",
          category: "doing",
          wip_limit: 3
        })
        |> ok!()

      assert result["list"]["name"] == "Review"
      assert result["board_id"] == ctx.board.id
      assert List.last(list_names(ctx.board)) == "Review"
      {:ok, column} = Boards.find_column(ctx.board, "Review")
      assert column.category == "doing"
      assert column.wip_limit == 3
    end

    test "a name already in use, in any case, is refused", ctx do
      before = list_names(ctx.board)
      taken = hd(before)

      assert ctx.conn
             |> call("create_list", %{board: "delivery", name: String.upcase(taken)})
             |> error!() =~ "already has a list called"

      assert list_names(ctx.board) == before
    end

    test "an unknown category is refused", ctx do
      assert ctx.conn
             |> call("create_list", %{board: "delivery", name: "Odd", category: "sideways"})
             |> error!() =~ "not saved"

      refute "Odd" in list_names(ctx.board)
    end

    test "needs a name", ctx do
      assert ctx.conn |> call("create_list", %{board: "delivery", name: " "}) |> error!() =~
               "name is required"
    end

    test "works on a board shared for writing", ctx do
      ctx.conn |> call("create_list", %{board: ctx.shared.id, name: "Extra"}) |> ok!()
      assert "Extra" in list_names(ctx.shared)
    end

    test "not on a stranger's board", ctx do
      ctx.conn |> call("create_list", %{board: ctx.theirs.id, name: "Mine now"}) |> error!()
      refute "Mine now" in list_names(ctx.theirs)
    end

    test "a read-only token cannot", ctx do
      ctx.conn
      |> with_token(ctx.user, scope: "read")
      |> call("create_list", %{board: "delivery", name: "Nope"})
      |> error!()

      refute "Nope" in list_names(ctx.board)
    end
  end

  describe "delete_list" do
    setup ctx do
      {:ok, empty} = Boards.create_column(ctx.board, %{"name" => "Spare"})
      %{empty: empty}
    end

    test "an empty list goes", ctx do
      result = ctx.conn |> call("delete_list", %{board: "delivery", list: "spare"}) |> ok!()
      assert result["deleted"] == true
      assert result["deleted_cards"] == 0
      refute "Spare" in list_names(ctx.board)
    end

    test "by id as well as by name", ctx do
      ctx.conn |> call("delete_list", %{board: "delivery", list: ctx.empty.id}) |> ok!()
      refute "Spare" in list_names(ctx.board)
    end

    test "a list holding cards is refused and kept, counting archived ones", ctx do
      other = card_fixture(ctx.roles.ready, %{"title" => "Archived one"})
      {:ok, _} = Boards.archive_card(other)

      text =
        ctx.conn
        |> call("delete_list", %{board: "delivery", list: ctx.roles.ready.name})
        |> error!()

      assert text =~ "list_not_empty"
      assert text =~ "2 card(s), 1 of them archived"
      assert text =~ "with_cards = true"
      assert ctx.roles.ready.name in list_names(ctx.board)
      assert Boards.get_card(ctx.card.id)
    end

    test "with_cards = true deletes the list and its cards", ctx do
      result =
        ctx.conn
        |> call("delete_list", %{board: "delivery", list: ctx.roles.ready.name, with_cards: true})
        |> ok!()

      assert result["deleted_cards"] == 1
      refute ctx.roles.ready.name in list_names(ctx.board)
      assert Boards.get_card(ctx.card.id) == nil
    end

    test "an unknown list names the real ones", ctx do
      text = ctx.conn |> call("delete_list", %{board: "delivery", list: "Nowhere"}) |> error!()
      assert text =~ "no list called “Nowhere”"
      assert text =~ "Spare"
    end

    test "with_cards must be true or false", ctx do
      assert ctx.conn
             |> call("delete_list", %{board: "delivery", list: "Spare", with_cards: "yes"})
             |> error!() =~ "with_cards must be true or false"

      assert "Spare" in list_names(ctx.board)
    end

    test "not on a stranger's board", ctx do
      name = hd(ctx.theirs.columns).name

      ctx.conn
      |> call("delete_list", %{board: ctx.theirs.id, list: name, with_cards: true})
      |> error!()

      assert name in list_names(ctx.theirs)
      assert Boards.get_card(ctx.secret.id)
    end

    test "a read-only token cannot", ctx do
      ctx.conn
      |> with_token(ctx.user, scope: "read")
      |> call("delete_list", %{board: "delivery", list: "Spare"})
      |> error!()

      assert "Spare" in list_names(ctx.board)
    end
  end

  describe "create_board" do
    test "makes a board of the caller's own with the default lists", ctx do
      result = ctx.conn |> call("create_board", %{name: "Launch", code: "launch"}) |> ok!()

      assert result["code"] == "launch"
      assert result["owner"] == "yours"
      assert result["ready"]
      assert result["url"] =~ "/boards/#{result["id"]}"

      board = Boards.get_board!(result["id"])
      assert board.owner_id == ctx.user.id
      assert length(board.columns) == 4
      assert ctx.conn |> get(~p"/api/boards/launch") |> json_response(200)
    end

    test "with a template's lists", ctx do
      result = ctx.conn |> call("create_board", %{name: "Light", template: "Simple"}) |> ok!()
      {:ok, t} = Boards.find_template("Simple")
      assert Enum.map(result["lists"], & &1["name"]) == Enum.map(t.columns, & &1["name"])
    end

    test "with lists of its own, kept as a template", ctx do
      name = "MCP lists #{System.unique_integer([:positive])}"

      result =
        ctx.conn
        |> call("create_board", %{
          name: "Own",
          lists: ["Ideas", "In Progress", "Done"],
          save_template: name
        })
        |> ok!()

      assert Enum.map(result["lists"], & &1["name"]) == ["Ideas", "In Progress", "Done"]
      assert {:ok, t} = Boards.find_template(name)
      assert Boards.get_board!(result["id"]).template_id == t.id
    end

    test "lists that are not strings are refused, and make nothing", ctx do
      assert ctx.conn |> call("create_board", %{name: "Odd", lists: [1, 2]}) |> error!() =~
               "lists must be a list of strings"

      refute Enum.any?(Slipdock.Access.list_boards(ctx.user), &(&1.name == "Odd"))
    end

    test "a template name already taken is refused, and makes nothing", ctx do
      assert ctx.conn
             |> call("create_board", %{name: "Clash", lists: ["A"], save_template: "Simple"})
             |> error!() =~ "a template called “Simple” already exists"

      refute Enum.any?(Slipdock.Access.list_boards(ctx.user), &(&1.name == "Clash"))
    end

    test "an unknown template names the real ones, and makes nothing", ctx do
      text = ctx.conn |> call("create_board", %{name: "Nope", template: "Imaginary"}) |> error!()
      assert text =~ "no template called"
      assert text =~ "Simple"
      refute Enum.any?(Slipdock.Access.list_boards(ctx.user), &(&1.name == "Nope"))
    end

    test "a code already taken is refused", ctx do
      assert ctx.conn |> call("create_board", %{name: "Again", code: "delivery"}) |> error!() =~
               "not saved"
    end

    test "needs a name", ctx do
      assert ctx.conn |> call("create_board", %{}) |> error!() =~ "name is required"
    end

    test "a board-scoped token cannot make one", ctx do
      assert ctx.conn
             |> with_token(ctx.user, scope_boards: [ctx.board.id])
             |> call("create_board", %{name: "Escape"})
             |> error!() =~ "scope doesn't allow it"

      refute Enum.any?(Slipdock.Access.list_boards(ctx.user), &(&1.name == "Escape"))
    end

    test "a read-only token cannot", ctx do
      ctx.conn
      |> with_token(ctx.user, scope: "read")
      |> call("create_board", %{name: "Ro"})
      |> error!()

      refute Enum.any?(Slipdock.Access.list_boards(ctx.user), &(&1.name == "Ro"))
    end
  end

  describe "archive_board" do
    test "archives it off the list, and restore brings it back", ctx do
      result = ctx.conn |> call("archive_board", %{board: "delivery"}) |> ok!()
      assert result["archived"] == true
      assert Boards.get_board!(ctx.board.id).archived_at

      %{"boards" => boards} = ctx.conn |> call("list_boards", %{}) |> ok!()
      refute Enum.any?(boards, &(&1["id"] == ctx.board.id))

      result = ctx.conn |> call("archive_board", %{board: "delivery", restore: true}) |> ok!()
      assert result["archived"] == false
      assert Boards.get_board!(ctx.board.id).archived_at == nil
    end

    test "a board shared for writing is not the caller's to archive", ctx do
      assert ctx.conn |> call("archive_board", %{board: ctx.shared.id}) |> error!() =~
               "you don't own this board"

      assert Boards.get_board!(ctx.shared.id).archived_at == nil
    end

    test "a sub-board goes with its card", ctx do
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.card, t)

      assert ctx.conn |> call("archive_board", %{board: sub.id}) |> error!() =~
               "archive its card instead"
    end

    test "not a stranger's board", ctx do
      ctx.conn |> call("archive_board", %{board: ctx.theirs.id}) |> error!()
      assert Boards.get_board!(ctx.theirs.id).archived_at == nil
    end
  end

  describe "delete_board" do
    test "with its code as confirm, it is gone with its cards", ctx do
      result =
        ctx.conn |> call("delete_board", %{board: ctx.board.id, confirm: "Delivery"}) |> ok!()

      assert result["deleted"] == true
      assert Boards.get_board(ctx.board.id) == nil
      assert Boards.get_card(ctx.card.id) == nil
    end

    test "a wrong or missing confirm deletes nothing, and names the code", ctx do
      for args <- [
            %{board: "delivery"},
            %{board: "delivery", confirm: "yes"},
            %{board: "delivery", confirm: true}
          ] do
        text = ctx.conn |> call("delete_board", args) |> error!()
        assert text =~ ~s("delivery")
        assert text =~ "archive_board"
      end

      assert Boards.get_board(ctx.board.id)
    end

    test "a board shared for writing is not the caller's to delete", ctx do
      assert ctx.conn
             |> call("delete_board", %{board: ctx.shared.id, confirm: "shared"})
             |> error!() =~ "you don't own this board"

      assert Boards.get_board(ctx.shared.id)
    end

    test "a sub-board goes with its card", ctx do
      {:ok, t} = Boards.find_template("Simple")
      {:ok, sub} = Boards.create_sub_board(ctx.card, t)
      sub = Boards.get_board!(sub.id)

      assert ctx.conn |> call("delete_board", %{board: sub.id, confirm: sub.code}) |> error!() =~
               "goes with its card"

      assert Boards.get_board(sub.id)
    end

    test "not a stranger's board", ctx do
      ctx.conn |> call("delete_board", %{board: ctx.theirs.id, confirm: "theirs"}) |> error!()
      assert Boards.get_board(ctx.theirs.id)
    end

    test "a read-only token cannot", ctx do
      assert ctx.conn
             |> with_token(ctx.user, scope: "read")
             |> call("delete_board", %{board: "delivery", confirm: "delivery"})
             |> error!() =~ "read-only"

      assert Boards.get_board(ctx.board.id)
    end
  end
end
