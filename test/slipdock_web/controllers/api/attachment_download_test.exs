defmodule SlipdockWeb.API.AttachmentDownloadTest do
  @moduledoc """
  `GET /api/attachments/:id` and `/api/attachments/:id/file` (#920): a file's
  details and its bytes for a token, checked as reading its card or page is,
  with the token's scope narrowing that.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

  setup %{conn: conn, user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Downloads", "code" => "dl920"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Has a file"})
    page = page_fixture(board, %{"title" => "Runbook"}, user: user)
    conn = put_req_header(conn, "accept", "application/json")

    %{conn: conn, board: board, card: card, page: page}
  end

  defp upload(conn, path, name, bytes, type \\ "image/png") do
    file = Path.join(System.tmp_dir!(), "api-dl-#{System.unique_integer([:positive])}")
    File.write!(file, bytes)
    on_exit(fn -> File.rm(file) end)

    %{"attachment" => %{"id" => id}} =
      conn
      |> post(path, %{file: %Plug.Upload{path: file, filename: name, content_type: type}})
      |> json_response(201)

    id
  end

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "downloads", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  describe "a card's file" do
    test "its details name the card, and its bytes come back as a download", %{
      conn: conn,
      card: card
    } do
      id = upload(conn, "/api/cards/#{card.id}/attachments", "shot.png", @png)

      assert %{
               "attachment" => %{
                 "id" => ^id,
                 "filename" => "shot.png",
                 "content_type" => "image/png",
                 "size" => 12,
                 "card" => card_id
               }
             } = conn |> get("/api/attachments/#{id}") |> json_response(200)

      assert card_id == card.id

      served = get(conn, "/api/attachments/#{id}/file")
      assert served.status == 200
      assert served.resp_body == @png
      assert get_resp_header(served, "content-type") == ["image/png"]
      # Even an image is a download here: this is for saving, not showing.
      assert [disposition] = get_resp_header(served, "content-disposition")
      assert disposition =~ ~s(attachment; filename="shot.png")
      assert get_resp_header(served, "x-content-type-options") == ["nosniff"]
    end

    test "a Range asks for just those bytes", %{conn: conn, card: card} do
      id = upload(conn, "/api/cards/#{card.id}/attachments", "shot.png", @png)

      served = conn |> put_req_header("range", "bytes=0-3") |> get("/api/attachments/#{id}/file")

      assert served.status == 206
      assert served.resp_body == binary_part(@png, 0, 4)
    end

    test "a file whose bytes are gone is a 404 that says so", %{conn: conn, card: card} do
      id = upload(conn, "/api/cards/#{card.id}/attachments", "gone.png", @png)
      [stored] = Boards.get_card!(card.id).attachments
      File.rm!(Boards.attachment_path(stored))

      assert %{"error" => "the file's bytes not found"} =
               conn |> get("/api/attachments/#{id}/file") |> json_response(404)
    end
  end

  describe "a page's file" do
    test "its details name the page, and the bytes are the ones sent", %{conn: conn, page: page} do
      id =
        upload(conn, "/api/pages/#{page.id}/attachments", "notes.txt", "hello", "text/plain")

      assert %{"attachment" => %{"page" => code, "filename" => "notes.txt"}} =
               conn |> get("/api/attachments/#{id}") |> json_response(200)

      assert code == page.code
      assert conn |> get("/api/attachments/#{id}/file") |> response(200) == "hello"
    end

    test "a draft's file is not there to a reader who can't edit", %{
      conn: conn,
      board: board,
      user: user
    } do
      reader = user_fixture("dl920.reader@example.com")
      share_fixture(board, reader, "read")
      draft = page_fixture(board, %{"title" => "Half", "status" => "draft"}, user: user)
      id = upload(conn, "/api/pages/#{draft.id}/attachments", "d.txt", "draft", "text/plain")

      as_reader = with_token(reader, [])

      for path <- ["/api/attachments/#{id}", "/api/attachments/#{id}/file"] do
        assert %{"error" => "attachment not found"} =
                 as_reader |> get(path) |> json_response(404)
      end

      assert conn |> get("/api/attachments/#{id}/file") |> response(200) == "draft"
    end
  end

  describe "the refusals" do
    test "a stranger's file reads the same as one that never was", %{conn: conn} do
      stranger = user_fixture("dl920.stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs920"}, owner: stranger)
      secret = card_fixture(hd(theirs.columns), %{"title" => "Theirs"})
      id = upload(with_token(stranger, []), "/api/cards/#{secret.id}/attachments", "s.png", @png)

      for path <- [
            "/api/attachments/#{id}",
            "/api/attachments/#{id}/file",
            "/api/attachments/99999999/file"
          ] do
        assert %{"error" => "attachment not found"} = conn |> get(path) |> json_response(404)
      end
    end

    test "a token scoped to another board is told it is the scope", %{
      conn: conn,
      user: user,
      card: card
    } do
      id = upload(conn, "/api/cards/#{card.id}/attachments", "shot.png", @png)
      other = board_fixture(%{"name" => "Other", "code" => "other920"}, owner: user)
      scoped = with_token(user, scope_boards: [other.id])

      assert %{"error" => "forbidden: this API token's scope" <> _} =
               scoped |> get("/api/attachments/#{id}/file") |> json_response(403)
    end

    test "a read-only token may download", %{conn: conn, user: user, card: card} do
      id = upload(conn, "/api/cards/#{card.id}/attachments", "shot.png", @png)

      assert user
             |> with_token(scope: "read")
             |> get("/api/attachments/#{id}/file")
             |> response(200) == @png
    end

    test "an id that is not a number is a 422 that says what one is", %{conn: conn} do
      assert %{"error" => "an attachment id is a number, like 42"} =
               conn |> get("/api/attachments/shot.png/file") |> json_response(422)
    end

    test "no token gets nothing", %{conn: conn, card: card} do
      id = upload(conn, "/api/cards/#{card.id}/attachments", "shot.png", @png)

      assert build_conn()
             |> put_req_header("accept", "application/json")
             |> get("/api/attachments/#{id}/file")
             |> response(401)
    end
  end
end
