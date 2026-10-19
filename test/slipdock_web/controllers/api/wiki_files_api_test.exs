defmodule SlipdockWeb.API.WikiFilesAPITest do
  @moduledoc """
  The wiki's files that are not pages, over the API (#1156): listed by path,
  and read by path with a token, so an agent can fetch a Tool's board files
  from the `Tool` folder its install made.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Accounts
  alias Slipdock.Wiki.{Files, Folders}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Wiki Files API"}, owner: user)
    {:ok, tool} = Folders.create(board, %{"name" => "Tool"})
    {:ok, templates} = Folders.create(board, %{"name" => "Tool/templates"})
    {:ok, other} = Folders.create(board, %{"name" => "Other"})

    top = put_file(board, "readme.txt", nil, "at the top")
    script = put_file(board, "build.py", tool.id, "print('hi')\n")
    docx = put_file(board, "cv template.docx", templates.id, <<0, 1, 2, 255>>)
    elsewhere = put_file(board, "notes.md", other.id, "# Notes")

    %{board: board, top: top, script: script, docx: docx, elsewhere: elsewhere}
  end

  defp put_file(board, name, folder_id, bytes) do
    path = Path.join(System.tmp_dir!(), "wfa-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    {:ok, file} = Files.create(board, %{name: name, folder_id: folder_id}, path)
    file
  end

  defp with_token(user, opts \\ []) do
    {token, _} = Accounts.create_api_token(user, "agent", Keyword.put_new(opts, :scope, "read"))
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "GET /api/boards/:board/files" do
    test "every live file, by its path, with where to fetch it", %{user: user, board: board} do
      body = user |> with_token() |> get("/api/boards/#{board.code}/files") |> json_response(200)

      assert body["board"] == board.code

      assert Enum.map(body["files"], & &1["path"]) == [
               "Other/notes.md",
               "readme.txt",
               "Tool/build.py",
               "Tool/templates/cv template.docx"
             ]

      script = Enum.find(body["files"], &(&1["name"] == "build.py"))
      assert script["folder"] == "Tool"
      assert script["size"] == byte_size("print('hi')\n")

      assert script["sha256"] ==
               :crypto.hash(:sha256, "print('hi')\n") |> Base.encode16(case: :lower)

      assert script["url"] == "/api/boards/#{board.code}/files/Tool/build.py"

      top = Enum.find(body["files"], &(&1["name"] == "readme.txt"))
      assert top["folder"] == nil

      docx = Enum.find(body["files"], &(&1["name"] == "cv template.docx"))
      assert docx["url"] == "/api/boards/#{board.code}/files/Tool/templates/cv%20template.docx"
    end

    test "folder keeps to one folder and everything under it, whatever its case", %{
      user: user,
      board: board
    } do
      paths = fn folder ->
        user
        |> with_token()
        |> get("/api/boards/#{board.code}/files", %{folder: folder})
        |> json_response(200)
        |> Map.fetch!("files")
        |> Enum.map(& &1["path"])
      end

      assert paths.("tool") == ["Tool/build.py", "Tool/templates/cv template.docx"]
      assert paths.("Tool/templates/") == ["Tool/templates/cv template.docx"]
      # A folder whose name only starts the same way is not under it.
      assert paths.("Too") == []
    end

    test "a folder that isn't a path is a 400", %{user: user, board: board} do
      assert %{"error" => error} =
               user
               |> with_token()
               |> get("/api/boards/#{board.code}/files", %{folder: ["Tool"]})
               |> json_response(400)

      assert error =~ "folder"
    end

    test "an archived file is not listed, and can't be fetched", %{
      user: user,
      board: board,
      script: script
    } do
      {:ok, _} = Files.archive(script)

      listed =
        user |> with_token() |> get("/api/boards/#{board.code}/files") |> json_response(200)

      refute Enum.any?(listed["files"], &(&1["name"] == "build.py"))

      assert user
             |> with_token()
             |> get("/api/boards/#{board.code}/files/Tool/build.py")
             |> json_response(404)
    end
  end

  describe "GET /api/boards/:board/files/*path" do
    test "the bytes, as a download under the file's name", %{user: user, board: board} do
      conn = user |> with_token() |> get("/api/boards/#{board.code}/files/Tool/build.py")

      assert response(conn, 200) == "print('hi')\n"
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "application/octet-stream"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment; filename="build.py")
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      sha = :crypto.hash(:sha256, "print('hi')\n") |> Base.encode16(case: :lower)
      assert get_resp_header(conn, "etag") == [~s("#{sha}")]
    end

    test "the path matches without regard to case, nested and encoded alike", %{
      user: user,
      board: board
    } do
      assert user
             |> with_token()
             |> get("/api/boards/#{board.code}/files/tool/TEMPLATES/CV%20Template.docx")
             |> response(200) == <<0, 1, 2, 255>>

      assert user
             |> with_token()
             |> get("/api/boards/#{board.id}/files/readme.txt")
             |> response(200) ==
               "at the top"
    end

    test "the name alone is not enough when the file is in a folder", %{user: user, board: board} do
      assert %{"error" => error} =
               user
               |> with_token()
               |> get("/api/boards/#{board.code}/files/build.py")
               |> json_response(404)

      assert error =~ "build.py"
    end
  end

  describe "who may read" do
    test "somebody who can't read the board gets a 404, as for a board that isn't there", %{
      board: board
    } do
      stranger = user_fixture("wiki-files-stranger@example.com")

      assert stranger
             |> with_token()
             |> get("/api/boards/#{board.code}/files")
             |> json_response(404)

      assert stranger
             |> with_token()
             |> get("/api/boards/#{board.code}/files/Tool/build.py")
             |> json_response(404)
    end

    test "a token confined to other boards is refused, and says it is the token", %{
      user: user,
      board: board
    } do
      other = board_fixture(%{"name" => "Wiki Files Elsewhere"}, owner: user)

      assert %{"error" => error} =
               user
               |> with_token(scope_boards: [other.id])
               |> get("/api/boards/#{board.code}/files/Tool/build.py")
               |> json_response(403)

      assert error =~ "token"
    end

    test "with no token it is a 401", %{board: board} do
      assert build_conn()
             |> put_req_header("accept", "application/json")
             |> get("/api/boards/#{board.code}/files")
             |> json_response(401)
    end
  end
end
