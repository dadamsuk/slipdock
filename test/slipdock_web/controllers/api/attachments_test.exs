defmodule SlipdockWeb.API.AttachmentsTest do
  @moduledoc """
  Files over the API: `POST /api/cards/:id/attachments` and
  `/api/pages/:id/attachments` with the multipart field `file`, the listing
  beside each, and the delete. What comes back has to be enough to embed the
  file — the `markdown` — and the bytes have to be the ones that were sent.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Wiki}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

  setup %{conn: conn, user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Files API"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Has a screenshot"})
    page = page_fixture(board, %{"title" => "Runbook"}, user: user)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      card: card,
      page: page
    }
  end

  defp upload(name, bytes, type \\ "image/png") do
    path = Path.join(System.tmp_dir!(), "api-upload-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: name, content_type: type}
  end

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "agent", opts)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  describe "a card" do
    test "takes an image, keeps its bytes, and hands back the Markdown that shows it", %{
      conn: conn,
      user: user,
      card: card
    } do
      body =
        conn
        |> post("/api/cards/#{card.id}/attachments", %{file: upload("shot.png", @png)})
        |> json_response(201)

      assert %{
               "attachment" => %{
                 "id" => id,
                 "filename" => "shot.png",
                 "content_type" => "image/png",
                 "size" => 12,
                 "url" => url,
                 "markdown" => markdown
               }
             } = body

      assert url == "/attachments/#{id}/shot.png"
      assert markdown == "![shot.png](#{url})"

      [stored] = Boards.get_card!(card.id).attachments
      assert stored.id == id
      assert File.read!(Boards.attachment_path(stored)) == @png

      # It shows on the card, and it is served back as the image it is.
      assert %{"card" => %{"attachments" => [%{"id" => ^id}]}} =
               conn |> get("/api/cards/#{card.id}") |> json_response(200)

      served = build_conn() |> log_in_user(user) |> get(url)
      assert served.status == 200
      assert served.resp_body == @png
    end

    test "a file that is not an image is a link, not an embed", %{conn: conn, card: card} do
      assert %{"attachment" => %{"markdown" => "[notes.txt](" <> _}} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{
                 file: upload("notes.txt", "hello", "text/plain")
               })
               |> json_response(201)
    end

    test "curl's octet-stream gives way to the file's extension", %{conn: conn, card: card} do
      assert %{"attachment" => %{"content_type" => "image/jpeg"}} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{
                 file: upload("photo.JPG", @png, "application/octet-stream")
               })
               |> json_response(201)
    end

    test "`filename` names it instead of the name it was sent with", %{conn: conn, card: card} do
      assert %{"attachment" => %{"filename" => "after.png"}} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{
                 file: upload("tmp123", @png),
                 filename: "../../after.png"
               })
               |> json_response(201)
    end

    test "is listed, oldest first", %{conn: conn, card: card} do
      {:ok, a} =
        Boards.add_attachment(
          card,
          %{filename: "a.png", content_type: "image/png"},
          upload("a.png", @png).path
        )

      assert %{"attachments" => [%{"id" => id, "markdown" => "![a.png]" <> _}]} =
               conn |> get("/api/cards/#{card.id}/attachments") |> json_response(200)

      assert id == a.id
    end

    test "is deleted, bytes and all", %{conn: conn, card: card} do
      {:ok, a} =
        Boards.add_attachment(
          card,
          %{filename: "a.png", content_type: "image/png"},
          upload("a.png", @png).path
        )

      path = Boards.attachment_path(a)

      assert %{"ok" => true} =
               conn
               |> delete("/api/cards/#{card.id}/attachments/#{a.id}")
               |> json_response(200)

      assert Boards.get_card!(card.id).attachments == []
      refute File.exists?(path)
    end
  end

  describe "the card front" do
    test "an upload may be kept off it from the start", %{conn: conn, card: card} do
      assert %{"attachment" => %{"hide_on_card" => false}} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{file: upload("a.png", @png)})
               |> json_response(201)

      assert %{"attachment" => %{"id" => id, "hide_on_card" => true}} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{
                 file: upload("b.png", @png),
                 hide_on_card: "true"
               })
               |> json_response(201)

      assert Boards.get_attachment!(id).hide_on_card
    end

    test "PATCH keeps an image off it, and puts it back", %{conn: conn, card: card} do
      {:ok, a} =
        Boards.add_attachment(
          card,
          %{filename: "a.png", content_type: "image/png"},
          upload("a.png", @png).path
        )

      assert %{"attachment" => %{"hide_on_card" => true}} =
               conn
               |> patch("/api/cards/#{card.id}/attachments/#{a.id}", %{hide_on_card: true})
               |> json_response(200)

      assert Boards.get_attachment!(a.id).hide_on_card

      # Leaving the field out changes nothing.
      assert %{"attachment" => %{"hide_on_card" => true}} =
               conn
               |> patch("/api/cards/#{card.id}/attachments/#{a.id}", %{})
               |> json_response(200)

      assert %{"attachment" => %{"hide_on_card" => false}} =
               conn
               |> patch("/api/cards/#{card.id}/attachments/#{a.id}", %{hide_on_card: false})
               |> json_response(200)

      refute Boards.get_attachment!(a.id).hide_on_card
    end

    test "a value that is not a boolean is a 422, and changes nothing", %{
      conn: conn,
      card: card
    } do
      {:ok, a} =
        Boards.add_attachment(
          card,
          %{filename: "a.png", content_type: "image/png"},
          upload("a.png", @png).path
        )

      assert %{"error" => "hide_on_card must be true or false"} =
               conn
               |> patch("/api/cards/#{card.id}/attachments/#{a.id}", %{hide_on_card: "yes"})
               |> json_response(422)

      assert conn
             |> post("/api/cards/#{card.id}/attachments", %{
               file: upload("b.png", @png),
               hide_on_card: "maybe"
             })
             |> json_response(422)

      refute Boards.get_attachment!(a.id).hide_on_card
      assert [_] = Boards.get_card!(card.id).attachments
    end

    test "another card's file, or a read-only token, cannot change it", %{
      conn: conn,
      user: user,
      board: board,
      card: card
    } do
      theirs = card_fixture(hd(board.columns), %{"title" => "Theirs"})

      {:ok, a} =
        Boards.add_attachment(
          theirs,
          %{filename: "a.png", content_type: "image/png"},
          upload("a.png", @png).path
        )

      assert conn
             |> patch("/api/cards/#{card.id}/attachments/#{a.id}", %{hide_on_card: true})
             |> json_response(404)

      assert with_token(user, scope: "read")
             |> patch("/api/cards/#{theirs.id}/attachments/#{a.id}", %{hide_on_card: true})
             |> json_response(403)

      refute Boards.get_attachment!(a.id).hide_on_card
    end
  end

  describe "transcribing" do
    setup %{card: card} do
      {:ok, a} =
        Boards.add_attachment(
          card,
          %{filename: "call.mp3", content_type: "audio/mpeg"},
          upload("call.mp3", "ID3 audio", "audio/mpeg").path
        )

      %{audio: a}
    end

    defp set_up_server do
      {:ok, _} =
        Slipdock.Settings.complete_setup(%{
          "admin_email" => "admin@example.com",
          "transcription_server_url" => "https://transcribe.example"
        })
    end

    test "a recording is sent, and its transcript read back", %{
      conn: conn,
      card: card,
      audio: audio
    } do
      set_up_server()

      Req.Test.stub(Slipdock.Transcription, fn conn ->
        if conn.request_path == "/v1/status",
          do: Req.Test.json(conn, %{"api_version" => "1.0.0"}),
          else: Req.Test.json(conn, %{"text" => "Ship it Friday."})
      end)

      assert %{"attachment" => %{"id" => id, "transcript_status" => status}} =
               conn
               |> post("/api/cards/#{card.id}/attachments/#{audio.id}/transcribe")
               |> json_response(202)

      assert id == audio.id
      # Inline here; on a server it would still be "running".
      assert status in ["running", "done"]

      assert %{
               "attachments" => [
                 %{"transcript_status" => "done", "transcript" => "Ship it Friday."}
               ]
             } = conn |> get("/api/cards/#{card.id}/attachments") |> json_response(200)
    end

    test "without a server, or for a file that isn't audio, is a 422", %{
      conn: conn,
      card: card,
      audio: audio
    } do
      assert %{"error" => "No transcription server is set up on this Slipdock."} =
               conn
               |> post("/api/cards/#{card.id}/attachments/#{audio.id}/transcribe")
               |> json_response(422)

      set_up_server()

      {:ok, pdf} =
        Boards.add_attachment(
          card,
          %{filename: "a.pdf", content_type: "application/pdf"},
          upload("a.pdf", "%PDF").path
        )

      assert %{"error" => "Only audio files can be transcribed."} =
               conn
               |> post("/api/cards/#{card.id}/attachments/#{pdf.id}/transcribe")
               |> json_response(422)
    end

    test "one already running is a 409", %{conn: conn, card: card, audio: audio} do
      set_up_server()

      {:ok, _} =
        Boards.update_attachment_transcript(audio, %{
          transcript_status: "running",
          transcript_started_at: DateTime.utc_now(:second)
        })

      assert %{"error" => "It is being transcribed already."} =
               conn
               |> post("/api/cards/#{card.id}/attachments/#{audio.id}/transcribe")
               |> json_response(409)
    end

    test "another card's recording is a 404; a read-only token a 403", %{
      conn: conn,
      user: user,
      board: board,
      audio: audio
    } do
      set_up_server()
      other = card_fixture(hd(board.columns), %{"title" => "Other"})

      assert conn
             |> post("/api/cards/#{other.id}/attachments/#{audio.id}/transcribe")
             |> json_response(404)

      assert with_token(user, scope: "read")
             |> post("/api/cards/#{audio.card_id}/attachments/#{audio.id}/transcribe")
             |> json_response(403)

      assert Boards.get_attachment!(audio.id).transcript_status == nil
    end
  end

  describe "the refusals" do
    test "no file field is a 422 that says how to send one", %{conn: conn, card: card} do
      assert %{"error" => error} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{name: "x"})
               |> json_response(422)

      assert error =~ "multipart form field `file`"

      assert %{"error" => error} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{file: "just a string"})
               |> json_response(422)

      assert error =~ "multipart file upload"
      assert Boards.get_card!(card.id).attachments == []
    end

    test "up to 250 MB is taken; a byte more is a 422, and nothing is stored", %{
      conn: conn,
      card: card
    } do
      assert Slipdock.Boards.Attachment.max_size() == 250 * 1024 * 1024

      # Sparse: the size a stat reports without writing 250 MB to disk.
      sparse = fn size ->
        path = Path.join(System.tmp_dir!(), "sparse-#{System.unique_integer([:positive])}")
        {:ok, io} = :file.open(path, [:write, :binary])
        {:ok, _} = :file.position(io, size - 1)
        :ok = :file.write(io, <<0>>)
        :ok = :file.close(io)
        on_exit(fn -> File.rm(path) end)
        %Plug.Upload{path: path, filename: "big.bin", content_type: "application/octet-stream"}
      end

      assert %{"details" => %{"size" => [msg]}} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{
                 file: sparse.(Slipdock.Boards.Attachment.max_size() + 1)
               })
               |> json_response(422)

      assert msg =~ "less than or equal to"
      assert Boards.get_card!(card.id).attachments == []
    end

    test "an empty file is a validation failure", %{conn: conn, card: card} do
      assert %{"details" => %{"size" => _}} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{file: upload("empty.png", "")})
               |> json_response(422)
    end

    test "a card that is not there is a 404", %{conn: conn} do
      assert %{"error" => "card not found"} =
               conn
               |> post("/api/cards/999999999/attachments", %{file: upload("a.png", @png)})
               |> json_response(404)
    end

    test "another card's file is not this card's to delete", %{conn: conn, board: board} do
      mine = card_fixture(hd(board.columns), %{"title" => "Mine"})
      theirs = card_fixture(hd(board.columns), %{"title" => "Theirs"})

      {:ok, a} =
        Boards.add_attachment(
          theirs,
          %{filename: "a.png", content_type: "image/png"},
          upload("a.png", @png).path
        )

      for id <- [a.id, "nope", 999_999_999] do
        assert %{"error" => "attachment not found"} =
                 conn
                 |> delete("/api/cards/#{mine.id}/attachments/#{id}")
                 |> json_response(404)
      end

      assert [_] = Boards.get_card!(theirs.id).attachments
    end

    test "a read-only token can list but not upload or delete", %{user: user, card: card} do
      {:ok, a} =
        Boards.add_attachment(
          card,
          %{filename: "a.png", content_type: "image/png"},
          upload("a.png", @png).path
        )

      conn = with_token(user, scope: "read")

      assert %{"attachments" => [_]} =
               conn |> get("/api/cards/#{card.id}/attachments") |> json_response(200)

      assert conn
             |> post("/api/cards/#{card.id}/attachments", %{file: upload("b.png", @png)})
             |> json_response(403)

      assert conn
             |> delete("/api/cards/#{card.id}/attachments/#{a.id}")
             |> json_response(403)

      assert [_] = Boards.get_card!(card.id).attachments
    end

    test "someone with no access to the board gets nothing", %{card: card} do
      conn = with_token(user_fixture("attachments.outsider@example.com"), [])

      assert %{"error" => "forbidden" <> _} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{file: upload("a.png", @png)})
               |> json_response(403)

      assert Boards.get_card!(card.id).attachments == []
    end
  end

  describe "a sha256 sent with the file (#1014)" do
    defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    test "that matches stores it, in either case", %{conn: conn, card: card} do
      for hash <- [sha(@png), String.upcase(sha(@png))] do
        assert %{"attachment" => %{"size" => 12}} =
                 conn
                 |> post("/api/cards/#{card.id}/attachments", %{
                   file: upload("shot.png", @png),
                   sha256: hash
                 })
                 |> json_response(201)
      end

      assert length(Boards.get_card!(card.id).attachments) == 2
    end

    test "that doesn't match is a 422 that says what arrived, and stores nothing", %{
      conn: conn,
      card: card
    } do
      # One bit flipped, the size unchanged: the damage only a hash shows.
      <<head::binary-size(5), byte, rest::binary>> = @png
      flipped = head <> <<Bitwise.bxor(byte, 2)>> <> rest

      assert %{"error" => error} =
               conn
               |> post("/api/cards/#{card.id}/attachments", %{
                 file: upload("shot.png", flipped),
                 sha256: sha(@png)
               })
               |> json_response(422)

      assert error =~ "sha256_mismatch"
      assert error =~ "12 bytes with sha256 #{sha(flipped)}"
      assert error =~ "not the #{sha(@png)} you sent"
      assert error =~ "nothing was stored"
      assert Boards.get_card!(card.id).attachments == []
    end

    test "that isn't a SHA-256 at all is a 422, and stores nothing", %{conn: conn, card: card} do
      for bad <- ["abc", String.duplicate("g", 64), sha(@png) <> "00"] do
        assert %{"error" => error} =
                 conn
                 |> post("/api/cards/#{card.id}/attachments", %{
                   file: upload("shot.png", @png),
                   sha256: bad
                 })
                 |> json_response(422)

        assert error =~ "64 hex characters"
      end

      assert Boards.get_card!(card.id).attachments == []
    end

    test "is checked on a page's upload too", %{conn: conn, page: page} do
      assert conn
             |> post("/api/pages/#{page.code}/attachments", %{
               file: upload("diagram.png", @png),
               sha256: sha("something else")
             })
             |> json_response(422)
             |> Map.fetch!("error") =~ "sha256_mismatch"

      assert Wiki.attachments(page) == []

      assert conn
             |> post("/api/pages/#{page.code}/attachments", %{
               file: upload("diagram.png", @png),
               sha256: sha(@png)
             })
             |> json_response(201)

      assert [_] = Wiki.attachments(page)
    end
  end

  describe "a page" do
    test "takes an image and hands back the Markdown for its body", %{
      conn: conn,
      user: user,
      page: page
    } do
      assert %{"attachment" => %{"id" => id, "markdown" => markdown, "url" => url}} =
               conn
               |> post("/api/pages/#{page.code}/attachments", %{file: upload("diagram.png", @png)})
               |> json_response(201)

      assert markdown == "![diagram.png](#{url})"
      assert [%{id: ^id}] = Wiki.attachments(page)

      assert %{"attachments" => [%{"id" => ^id}]} =
               conn |> get("/api/pages/#{page.code}/attachments") |> json_response(200)

      assert (build_conn() |> log_in_user(user) |> get(url)).resp_body == @png
    end

    test "deletes its own file and no other page's", %{conn: conn, board: board, page: page} do
      other = page_fixture(board, %{"title" => "Other"})

      {:ok, theirs} =
        Wiki.add_attachment(
          other,
          %{filename: "a.png", content_type: "image/png"},
          upload("a.png", @png).path
        )

      {:ok, mine} =
        Wiki.add_attachment(
          page,
          %{filename: "b.png", content_type: "image/png"},
          upload("b.png", @png).path
        )

      assert %{"error" => "attachment not found"} =
               conn
               |> delete("/api/pages/#{page.code}/attachments/#{theirs.id}")
               |> json_response(404)

      assert %{"ok" => true} =
               conn
               |> delete("/api/pages/#{page.code}/attachments/#{mine.id}")
               |> json_response(200)

      assert Wiki.attachments(page) == []
      assert [_] = Wiki.attachments(other)
    end

    test "with no file is a 422", %{conn: conn, page: page} do
      assert conn |> post("/api/pages/#{page.code}/attachments", %{}) |> json_response(422)
    end
  end
end

defmodule SlipdockWeb.API.AttachmentsLimitTest do
  @moduledoc "An upload past the owner's limit is the 402 that means stop, not a 422 to retry."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Settings}

  test "a file past the item limit is a 402 and nothing is stored", %{conn: conn, user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Full"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "The only one"})

    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

    path = Path.join(System.tmp_dir!(), "api-upload-#{System.unique_integer([:positive])}")
    File.write!(path, "12345")
    on_exit(fn -> File.rm(path) end)
    file = %Plug.Upload{path: path, filename: "a.txt", content_type: "text/plain"}

    body =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/api/cards/#{card.id}/attachments", %{file: file})
      |> json_response(402)

    assert body["error"] == "card_limit_reached"
    assert body["retryable"] == false
    assert Boards.get_card!(card.id).attachments == []
  end
end
