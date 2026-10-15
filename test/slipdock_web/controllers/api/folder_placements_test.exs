defmodule SlipdockWeb.API.FolderPlacementsTest do
  @moduledoc "Filing a folder in several folders over the API (#808, #809)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Wiki.FolderPlacements

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Brain", "code" => "fpapi"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal", "code" => "fpapijobs"}, owner: user)
    {:ok, home} = Wiki.create_folder(board, %{"name" => "Home"})
    {:ok, folder} = Wiki.create_folder(board, %{"name" => "Topic", "parent_id" => home.id})
    {:ok, other} = Wiki.create_folder(board, %{"name" => "Other"})

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      jobs: jobs,
      home: home,
      folder: folder,
      other: other
    }
  end

  defp patch_folder(conn, folder, body), do: patch(conn, "/api/folders/#{folder.id}", body)

  test "also files it by path, keeps its home, and the JSON says where", ctx do
    body = ctx.conn |> patch_folder(ctx.folder, %{"also" => "Other"}) |> json_response(200)
    assert body["folder"]["parent_id"] == ctx.home.id
    assert [%{"path" => "Other", "board" => "fpapi"}] = body["folder"]["also_in"]

    tree =
      ctx.conn |> get("/api/boards/fpapi/folders") |> json_response(200) |> Map.fetch!("folders")

    home = Enum.find(tree, &(&1["name"] == "Home"))
    assert [%{"name" => "Topic", "also_in" => [%{"path" => "Other"}]}] = home["folders"]
    assert Enum.find(tree, &(&1["name"] == "Other"))["also_in"] == []
  end

  test "by id, and by board-and-path route, with a rename alongside", ctx do
    body =
      ctx.conn
      |> patch("/api/boards/fpapi/folders/Home/Topic", %{
        "also" => ctx.other.id,
        "name" => "Subject"
      })
      |> json_response(200)

    assert body["folder"]["name"] == "Subject"
    assert [%{"folder_id" => id}] = body["folder"]["also_in"]
    assert id == ctx.other.id
  end

  test "not_in takes it out; the folder stays", ctx do
    ctx.conn |> patch_folder(ctx.folder, %{"also" => "Other"}) |> json_response(200)
    body = ctx.conn |> patch_folder(ctx.folder, %{"not_in" => "Other"}) |> json_response(200)
    assert body["folder"]["also_in"] == []
    assert Wiki.get_folder(ctx.folder.id).parent_id == ctx.home.id

    assert %{"error" => _} =
             ctx.conn |> patch_folder(ctx.folder, %{"not_in" => "Other"}) |> json_response(404)

    assert ctx.conn |> patch_folder(ctx.folder, %{"not_in" => "Never made"}) |> json_response(404)
  end

  test "refusals carry the reason", ctx do
    {:ok, inner} =
      Wiki.create_folder(ctx.board, %{"name" => "Inner", "parent_id" => ctx.folder.id})

    assert %{"error" => msg} =
             ctx.conn |> patch_folder(ctx.folder, %{"also" => "Home"}) |> json_response(422)

    assert msg =~ "home"

    assert %{"error" => msg} =
             ctx.conn |> patch_folder(ctx.folder, %{"also" => inner.id}) |> json_response(422)

    assert msg =~ "inside"

    {:ok, _} = Wiki.create_folder(ctx.jobs, %{"name" => "Notes"})

    assert %{"error" => msg} =
             ctx.conn
             |> patch_folder(ctx.folder, %{"also" => "Notes", "in_board" => "fpapijobs"})
             |> json_response(422)

    assert msg =~ "same vault"

    assert ctx.conn |> patch_folder(ctx.folder, %{"also" => ""}) |> json_response(400)

    assert ctx.conn
           |> patch_folder(ctx.folder, %{"also" => "/Journal/Notes"})
           |> json_response(422)
  end

  test "a folder id on a board the caller can't read is not found", ctx do
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
    {:ok, hidden} = Wiki.create_folder(theirs, %{"name" => "Hidden"})

    assert ctx.conn |> patch_folder(ctx.folder, %{"also" => hidden.id}) |> json_response(404)
  end

  test "write on the target is needed: a 403 with the reason", ctx do
    owner = user_fixture("owner@example.com")
    shared = board_fixture(%{"name" => "Shared", "code" => "fpshared"}, owner: owner)
    share_fixture(shared, ctx.user, "read")
    share_fixture(ctx.board, owner, "write")
    {:ok, vault} = Vaults.create_vault(owner, %{"name" => "V"})
    {:ok, _} = Vaults.add_mapping(vault, owner, %{path: "/", board: shared})
    {:ok, _} = Vaults.add_mapping(vault, owner, %{path: "/Brain", board: ctx.board})
    {:ok, notes} = Wiki.create_folder(shared, %{"name" => "Notes"})

    assert %{"error" => msg} =
             ctx.conn |> patch_folder(ctx.folder, %{"also" => notes.id}) |> json_response(403)

    assert msg =~ "edit both"
    assert FolderPlacements.folders(ctx.folder) == []
  end

  test "across the vault by vault path", ctx do
    {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "V"})
    {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.board})
    {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/Journal", board: ctx.jobs})
    {:ok, _} = Wiki.create_folder(ctx.jobs, %{"name" => "Notes"})

    body =
      ctx.conn |> patch_folder(ctx.folder, %{"also" => "/Journal/Notes"}) |> json_response(200)

    assert [%{"path" => "Notes", "board" => "fpapijobs"}] = body["folder"]["also_in"]

    body =
      ctx.conn
      |> patch_folder(ctx.folder, %{"not_in" => "Notes", "in_board" => "fpapijobs"})
      |> json_response(200)

    assert body["folder"]["also_in"] == []
  end

  test "a move to another board reports the placements it dropped", ctx do
    ctx.conn |> patch_folder(ctx.folder, %{"also" => "Other"}) |> json_response(200)

    body =
      ctx.conn
      |> patch_folder(ctx.folder, %{"to_board" => "fpapijobs"})
      |> json_response(200)

    assert body["report"]["folder_filing_dropped"] == [
             %{"folder" => "Home/Topic", "in" => "Other"}
           ]

    assert body["folder"]["also_in"] == []
  end

  describe "listing a folder (#811)" do
    setup ctx do
      page_fixture(ctx.board, %{"title" => "Inside", "folder_id" => ctx.folder.id})
      {:ok, _} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)
      :ok
    end

    test "the API's page list has the placed folder's pages, marked also", ctx do
      listed =
        ctx.conn
        |> get("/api/boards/fpapi/pages?folder=Other")
        |> json_response(200)
        |> Map.fetch!("pages")

      assert [%{"title" => "Inside", "also" => true}] = listed

      home =
        ctx.conn
        |> get("/api/boards/fpapi/pages?folder=Home/Topic")
        |> json_response(200)
        |> Map.fetch!("pages")

      assert [%{"title" => "Inside", "also" => false}] = home
    end

    test "MCP list_pages with a folder has them too", ctx do
      result =
        ctx.conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/mcp",
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "list_pages", arguments: %{board: "fpapi", folder: "Other"}}
          })
        )
        |> json_response(200)
        |> Map.fetch!("result")

      assert [%{"title" => "Inside", "also" => true, "folder" => "Home/Topic"}] =
               result["structuredContent"]["pages"]
    end
  end

  describe "GET a folder (#812)" do
    test "by path on its board, with also_in; a missing one is a 404", ctx do
      {:ok, _} = FolderPlacements.add(ctx.folder, ctx.other, ctx.user)

      body = ctx.conn |> get("/api/boards/fpapi/folders/Home/Topic") |> json_response(200)
      assert %{"path" => "Home/Topic", "also_in" => [%{"path" => "Other"}]} = body["folder"]

      assert ctx.conn |> get("/api/boards/fpapi/folders/Nowhere") |> json_response(404)
    end
  end

  describe "MCP file_folder (#812)" do
    defp mcp(conn, args) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "file_folder", arguments: args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")
    end

    test "also and not_in, by path, and the answer lists where it is filed", ctx do
      result = mcp(ctx.conn, %{board: "fpapi", folder: "Home/Topic", also: "Other"})

      assert %{"path" => "Home/Topic", "also_in" => [%{"path" => "Other", "board" => "fpapi"}]} =
               result["structuredContent"]

      result = mcp(ctx.conn, %{board: "fpapi", folder: "Topic", not_in: "Other"})
      assert result["structuredContent"]["also_in"] == []
      assert Wiki.get_folder(ctx.folder.id).parent_id == ctx.home.id
    end

    test "on another board of the vault, by in_board or by vault path", ctx do
      {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "V"})
      {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.board})
      {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/Journal", board: ctx.jobs})
      {:ok, _} = Wiki.create_folder(ctx.jobs, %{"name" => "Notes"})
      {:ok, _} = Wiki.create_folder(ctx.jobs, %{"name" => "Desk"})

      result = mcp(ctx.conn, %{board: "fpapi", folder: "Topic", also: "/Journal/Notes"})

      assert [%{"board" => "fpapijobs", "path" => "Notes"}] =
               result["structuredContent"]["also_in"]

      result =
        mcp(ctx.conn, %{board: "fpapi", folder: "Topic", also: "Desk", in_board: "fpapijobs"})

      assert length(result["structuredContent"]["also_in"]) == 2
    end

    test "refusals come back as tool errors with the reason", ctx do
      for {args, why} <- [
            {%{also: "Home"}, "home"},
            {%{also: "Home/Topic/Inner"}, "inside"},
            {%{}, "say where"},
            {%{not_in: "Other"}, "no placement"}
          ] do
        if why == "inside",
          do: Wiki.create_folder(ctx.board, %{"name" => "Inner", "parent_id" => ctx.folder.id})

        result = mcp(ctx.conn, Map.merge(%{board: "fpapi", folder: "Home/Topic"}, args))
        assert result["isError"] == true, inspect(args)
        assert hd(result["content"])["text"] =~ why
      end

      assert FolderPlacements.folders(ctx.folder) == []
    end
  end
end
