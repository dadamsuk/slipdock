defmodule SlipdockWeb.MCP.FileToolsTest do
  @moduledoc """
  `upload_file` and `download_file` (#919): a file put on a card or a page
  over MCP is a real attachment the HTTP API lists, a file comes back in the
  shape its kind calls for, and neither reaches past what the token may see.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Settings}
  alias SlipdockWeb.MCP.Tools.{DownloadFile, UploadFile}

  # The smallest PNG there is: one transparent pixel.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup %{user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Files", "code" => "files919"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Has files"})
    page = page_fixture(board, %{"title" => "Spec", "body" => "# Spec"}, user: user)

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs919"}, owner: stranger)
    secret = card_fixture(hd(theirs.columns), %{"title" => "Their card"})

    %{board: board, card: card, page: page, stranger: stranger, theirs: theirs, secret: secret}
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
    {token, _} = Accounts.create_api_token(user, "files", opts)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp upload!(conn, args), do: conn |> call("upload_file", args) |> ok!()

  defp card_files(card),
    do: Repo.preload(Boards.get_card!(card.id), :attachments, force: true).attachments

  describe "upload_file" do
    test "attaches base64 bytes to a card, as the HTTP API then lists them", ctx do
      %{"card" => card_id, "attachment" => a} =
        upload!(ctx.conn, %{
          card: ctx.card.id,
          filename: "shot.png",
          content_base64: Base.encode64(@png)
        })

      assert card_id == ctx.card.id
      assert a["filename"] == "shot.png"
      assert a["content_type"] == "image/png"
      assert a["size"] == byte_size(@png)
      assert a["markdown"] == "![shot.png](/attachments/#{a["id"]}/shot.png)"

      [listed] =
        ctx.conn
        |> get("/api/cards/#{ctx.card.id}/attachments")
        |> json_response(200)
        |> Map.fetch!("attachments")

      assert listed["id"] == a["id"]
      [stored] = card_files(ctx.card)
      assert File.read!(Boards.attachment_path(stored)) == @png
    end

    test "takes a text file's contents as they are, and hide_on_card", ctx do
      %{"attachment" => a} =
        upload!(ctx.conn, %{
          card: "##{ctx.card.id}",
          filename: "notes.md",
          text: "# Notes\n\nñ and ✓\n",
          hide_on_card: true
        })

      assert a["content_type"] == "text/markdown"
      assert a["hide_on_card"] == true
      assert a["markdown"] =~ "[notes.md]("
      refute a["markdown"] =~ "!["
      [stored] = card_files(ctx.card)
      assert File.read!(Boards.attachment_path(stored)) == "# Notes\n\nñ and ✓\n"
    end

    test "a content_type given wins over the name, and base64 may be wrapped", ctx do
      wrapped =
        @png |> Base.encode64() |> String.graphemes() |> Enum.chunk_every(20) |> Enum.join("\n")

      %{"attachment" => a} =
        upload!(ctx.conn, %{
          card: ctx.card.id,
          filename: "pixel",
          content_base64: wrapped,
          content_type: "image/png"
        })

      assert a["content_type"] == "image/png"
      assert a["size"] == byte_size(@png)
    end

    test "attaches to a wiki page by its code, or by slug with board", ctx do
      %{"page" => code, "attachment" => a} =
        upload!(ctx.conn, %{page: ctx.page.code, filename: "a.txt", text: "one"})

      assert code == ctx.page.code
      assert a["filename"] == "a.txt"

      upload!(ctx.conn, %{page: ctx.page.slug, board: "files919", filename: "b.txt", text: "two"})

      names = ctx.page |> Slipdock.Wiki.attachments() |> Enum.map(& &1.filename)
      assert names == ["a.txt", "b.txt"]
    end

    test "says what is wrong with the arguments, and stores nothing", ctx do
      bad = [
        {%{card: ctx.card.id, text: "x"}, "filename is required"},
        {%{card: ctx.card.id, filename: "a.txt"}, "content_base64 (any file) or text"},
        {%{card: ctx.card.id, filename: "a.txt", text: "x", content_base64: "eA=="}, "not both"},
        {%{card: ctx.card.id, filename: "a.bin", content_base64: "%%%"}, "not valid base64"},
        {%{card: ctx.card.id, filename: "a.txt", text: ""}, "empty"},
        {%{card: ctx.card.id, filename: "a.txt", text: 5}, "text must be a string"},
        {%{filename: "a.txt", text: "x"}, "card, or page"},
        {%{card: ctx.card.id, page: ctx.page.code, filename: "a.txt", text: "x"}, "not both"},
        {%{card: ctx.card.id, filename: "a.txt", text: "x", hide_on_card: "yes"}, "true or false"}
      ]

      for {args, message} <- bad do
        assert ctx.conn |> call("upload_file", args) |> error!() =~ message
      end

      assert card_files(ctx.card) == []
    end

    test "a file over the limit is refused before it is stored", ctx do
      big = String.duplicate("x", UploadFile.max_bytes() + 1)

      text =
        ctx.conn
        |> call("upload_file", %{card: ctx.card.id, filename: "big.txt", text: big})
        |> error!()

      assert text =~ "up to #{UploadFile.max_bytes()}"
      assert text =~ "slipdock attach"
      assert card_files(ctx.card) == []
    end

    test "the account's limit is the stop it is everywhere else", ctx do
      {:ok, _} =
        Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

      text =
        ctx.conn
        |> call("upload_file", %{card: ctx.card.id, filename: "a.txt", text: "x"})
        |> error!()

      assert text =~ "card_limit_reached"
      assert text =~ "Don't retry"
      assert card_files(ctx.card) == []
    end

    test "never reaches a stranger's card or page", ctx do
      their_page = page_fixture(ctx.theirs, %{"title" => "Theirs"}, user: ctx.stranger)

      assert ctx.conn
             |> call("upload_file", %{card: ctx.secret.id, filename: "a.txt", text: "x"})
             |> error!() =~ "you don't edit this card"

      assert ctx.conn
             |> call("upload_file", %{page: their_page.code, filename: "a.txt", text: "x"})
             |> error!() =~ "no page"

      assert card_files(ctx.secret) == []
      assert Slipdock.Wiki.attachments(their_page) == []
    end

    test "a reader of the board may not attach", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")

      text =
        conn_as(reader)
        |> call("upload_file", %{card: ctx.card.id, filename: "a.txt", text: "x"})
        |> error!()

      refute text =~ "no card"
      assert card_files(ctx.card) == []
    end

    test "a read-only token is refused", ctx do
      text =
        ctx.conn
        |> with_token(ctx.user, scope: "read")
        |> call("upload_file", %{card: ctx.card.id, filename: "a.txt", text: "x"})
        |> error!()

      assert text =~ "read-only"
      assert card_files(ctx.card) == []
    end

    test "a request big enough for a 10 MB file in base64 is read", ctx do
      # The old 1 MB body limit would have been a 413 for this.
      bytes = :crypto.strong_rand_bytes(2_000_000)

      %{"attachment" => a} =
        upload!(ctx.conn, %{
          card: ctx.card.id,
          filename: "blob.bin",
          content_base64: Base.encode64(bytes)
        })

      assert a["size"] == 2_000_000
      assert a["content_type"] == "application/octet-stream"
      assert SlipdockWeb.MCP.Plug.max_body() > ceil(UploadFile.max_bytes() * 4 / 3) + 1000
    end
  end

  describe "download_file" do
    defp attach(card, name, bytes, type) do
      path = Path.join(System.tmp_dir!(), "mcp-dl-#{System.unique_integer([:positive])}")
      File.write!(path, bytes)
      on_exit(fn -> File.rm(path) end)

      {:ok, a} =
        Boards.add_attachment(card, %{filename: name, content_type: type}, path)

      a
    end

    test "an image comes back as an image block after its details", ctx do
      a = attach(ctx.card, "shot.png", @png, "image/png")
      result = call(ctx.conn, "download_file", %{attachment: a.id})
      info = ok!(result)

      assert info["id"] == a.id
      assert info["card"] == ctx.card.id
      assert info["url"] == "http://www.example.com/attachments/#{a.id}/shot.png"

      assert [%{"type" => "text"}, %{"type" => "image"} = image] = result["content"]
      assert image["mimeType"] == "image/png"
      assert Base.decode64!(image["data"]) == @png
    end

    test "text comes back as text, and is cut where read_page cuts a body", ctx do
      a = attach(ctx.card, "notes.md", "# Notes ✓", "text/markdown")
      result = call(ctx.conn, "download_file", %{attachment: a.id})
      assert %{"text" => "# Notes ✓", "truncated" => false} = ok!(result)
      assert [%{"type" => "text"}] = result["content"]

      long = String.duplicate("é", DownloadFile.max_text() + 5)
      b = attach(ctx.card, "long.txt", long, "text/plain")
      info = ctx.conn |> call("download_file", %{attachment: b.id}) |> ok!()
      assert info["truncated"] == true
      assert String.length(info["text"]) == DownloadFile.max_text()
    end

    test "UTF-8 sent as octet-stream is read as text; real binary is a resource", ctx do
      a = attach(ctx.card, "data", "a,b\n1,2\n", "application/octet-stream")

      assert %{"text" => "a,b\n1,2\n"} =
               ctx.conn |> call("download_file", %{attachment: a.id}) |> ok!()

      bytes = <<0, 159, 146, 150, 1, 2, 3>>
      b = attach(ctx.card, "blob.bin", bytes, "application/octet-stream")
      result = call(ctx.conn, "download_file", %{attachment: b.id})
      refute Map.has_key?(ok!(result), "text")

      assert [_, %{"type" => "resource", "resource" => resource}] = result["content"]
      assert resource["mimeType"] == "application/octet-stream"
      assert resource["uri"] =~ "/attachments/#{b.id}/blob.bin"
      assert Base.decode64!(resource["blob"]) == bytes
    end

    test "a page's file, found through read_page's list", ctx do
      %{"attachment" => %{"id" => id}} =
        upload!(ctx.conn, %{page: ctx.page.code, filename: "p.txt", text: "on the page"})

      %{"attachments" => [listed]} =
        ctx.conn |> call("read_page", %{page: ctx.page.code}) |> ok!()

      assert listed["id"] == id
      assert listed["markdown"] == "[p.txt](/attachments/#{id}/p.txt)"

      info = ctx.conn |> call("download_file", %{attachment: id}) |> ok!()
      assert info["page"] == ctx.page.code
      assert info["text"] == "on the page"
    end

    test "a binary file over the limit is refused with the web link", ctx do
      bytes = :crypto.strong_rand_bytes(DownloadFile.max_bytes() + 1)
      a = attach(ctx.card, "huge.zip", bytes, "application/zip")
      text = ctx.conn |> call("download_file", %{attachment: a.id}) |> error!()
      assert text =~ "up to #{DownloadFile.max_bytes()}"
      assert text =~ "/attachments/#{a.id}/huge.zip"
    end

    test "a file whose bytes are gone says so", ctx do
      a = attach(ctx.card, "gone.txt", "x", "text/plain")
      File.rm!(Boards.attachment_path(a))
      assert ctx.conn |> call("download_file", %{attachment: a.id}) |> error!() =~ "missing"
    end

    test "a stranger's file, a scoped-out board's and one that never was read the same", ctx do
      theirs = attach(ctx.secret, "secret.txt", "secret", "text/plain")
      mine = attach(ctx.card, "mine.txt", "mine", "text/plain")
      other = board_fixture(%{"name" => "Other", "code" => "other919"}, owner: ctx.user)
      scoped = with_token(ctx.conn, ctx.user, scope_boards: [other.id])

      for {conn, id} <- [{ctx.conn, theirs.id}, {scoped, mine.id}, {ctx.conn, 99_999_999}] do
        assert conn |> call("download_file", %{attachment: id}) |> error!() ==
                 "no attachment you can see matches that"
      end
    end

    test "a draft page's file is not there to a reader who can't edit", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")
      draft = page_fixture(ctx.board, %{"title" => "Half", "status" => "draft"}, user: ctx.user)

      %{"attachment" => %{"id" => id}} =
        upload!(ctx.conn, %{page: draft.code, filename: "d.txt", text: "draft"})

      assert conn_as(reader) |> call("download_file", %{attachment: id}) |> error!() =~
               "no attachment"

      assert ctx.conn |> call("download_file", %{attachment: id}) |> ok!()
    end

    test "a read-only token may download, and a bad id is explained", ctx do
      a = attach(ctx.card, "r.txt", "read me", "text/plain")
      reader = with_token(ctx.conn, ctx.user, scope: "read")

      assert %{"text" => "read me"} =
               reader |> call("download_file", %{attachment: a.id}) |> ok!()

      assert ctx.conn |> call("download_file", %{}) |> error!() =~ "attachment is required"
      assert ctx.conn |> call("download_file", %{attachment: "x"}) |> error!() =~ "like 42"
    end
  end
end
