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

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  describe "the stored file's sha256 (#1015)" do
    test "upload_file returns it, so one call verifies the upload", ctx do
      %{"attachment" => a} =
        upload!(ctx.conn, %{
          card: ctx.card.id,
          filename: "shot.png",
          content_base64: Base.encode64(@png),
          sha256: sha256(@png)
        })

      assert a["sha256"] == sha256(@png)
      assert a["size"] == byte_size(@png)
      [stored] = card_files(ctx.card)
      assert a["sha256"] == sha256(File.read!(Boards.attachment_path(stored)))
    end

    test "content_base64 without a sha256 is refused, so damage can't be stored silently (#1040)",
         ctx do
      text =
        ctx.conn
        |> call("upload_file", %{
          card: ctx.card.id,
          filename: "shot.png",
          content_base64: Base.encode64(@png)
        })
        |> error!()

      assert text =~ "content_base64 needs sha256"
      assert card_files(ctx.card) == []

      # Text isn't base64, so it still needn't say.
      upload!(ctx.conn, %{card: ctx.card.id, filename: "n.txt", text: "plain"})
      assert [_] = card_files(ctx.card)
    end

    test "get_card lists it with the card's files", ctx do
      %{"attachment" => %{"id" => id}} =
        upload!(ctx.conn, %{card: ctx.card.id, filename: "n.txt", text: "card file"})

      %{"attachments" => [listed]} = ctx.conn |> call("get_card", %{card: ctx.card.id}) |> ok!()
      assert listed["id"] == id
      assert listed["sha256"] == sha256("card file")
    end

    test "upload_file to a page returns it too", ctx do
      %{"attachment" => a} =
        upload!(ctx.conn, %{page: ctx.page.code, filename: "a.txt", text: "one"})

      assert a["sha256"] == sha256("one")
    end
  end

  describe "upload_file" do
    test "attaches base64 bytes to a card, as the HTTP API then lists them", ctx do
      %{"card" => card_id, "attachment" => a} =
        upload!(ctx.conn, %{
          card: ctx.card.id,
          filename: "shot.png",
          content_base64: Base.encode64(@png),
          sha256: sha256(@png)
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
          sha256: sha256(@png),
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
        {%{card: ctx.card.id, filename: "a.bin", content_base64: "%%%", sha256: sha256("")},
         "not valid base64"},
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

    test "a sha256 that matches the decoded bytes stores them (#1014)", ctx do
      hash = :crypto.hash(:sha256, @png) |> Base.encode16(case: :lower)

      %{"attachment" => a} =
        upload!(ctx.conn, %{
          card: ctx.card.id,
          filename: "shot.png",
          content_base64: Base.encode64(@png),
          sha256: hash
        })

      assert a["size"] == byte_size(@png)

      upload!(ctx.conn, %{
        page: ctx.page.code,
        filename: "notes.md",
        text: "ñ ✓",
        sha256: :crypto.hash(:sha256, "ñ ✓") |> Base.encode16()
      })

      [stored] = card_files(ctx.card)
      assert File.read!(Boards.attachment_path(stored)) == @png
      assert [_] = Slipdock.Wiki.attachments(ctx.page)
    end

    test "bytes that changed on the way are refused against their sha256, and not stored",
         ctx do
      hash = :crypto.hash(:sha256, @png) |> Base.encode16(case: :lower)
      # The same length with one bit flipped, as the base64 came out of a model.
      <<head::binary-size(40), byte, rest::binary>> = @png
      flipped = head <> <<Bitwise.bxor(byte, 2)>> <> rest
      flipped_hash = :crypto.hash(:sha256, flipped) |> Base.encode16(case: :lower)

      text =
        ctx.conn
        |> call("upload_file", %{
          card: ctx.card.id,
          filename: "shot.png",
          content_base64: Base.encode64(flipped),
          sha256: hash
        })
        |> error!()

      assert text =~ "sha256_mismatch"
      assert text =~ "#{byte_size(@png)} bytes with sha256 #{flipped_hash}"
      assert text =~ "nothing was stored"

      assert ctx.conn
             |> call("upload_file", %{
               page: ctx.page.code,
               filename: "a.txt",
               text: "x",
               sha256: "not-a-hash"
             })
             |> error!() =~ "64 hex characters"

      assert card_files(ctx.card) == []
      assert Slipdock.Wiki.attachments(ctx.page) == []
    end

    test "base64 with a run repeated mid-string decodes longer, and the sha256 refuses it (#1018)",
         ctx do
      # The second file damaged on 2026-10-16: 8 bytes longer, wrong from
      # offset ~4085 to the end. Eleven base64 characters said twice by the
      # model do exactly that, and the server decodes what it was given.
      bytes = :crypto.strong_rand_bytes(9_834)
      b64 = Base.encode64(bytes)
      at = div(4_085, 3) * 4
      repeated = binary_part(b64, 0, at + 11) <> binary_part(b64, at, byte_size(b64) - at)
      hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      assert ctx.conn
             |> call("upload_file", %{
               card: ctx.card.id,
               filename: "long.bin",
               content_base64: repeated,
               sha256: hash
             })
             |> error!() =~ "sha256_mismatch: the file arrived as 9842 bytes"

      assert card_files(ctx.card) == []
    end

    test "base64 made outside a model comes back byte for byte, wrapped or not (#1018)", ctx do
      # The control experiment, as run against production: no model, so no damage.
      bytes = :crypto.strong_rand_bytes(1_048_576)
      b64 = Base.encode64(bytes)

      for {name, b64} <- [
            {"flat.bin", b64},
            {"wrapped.bin", ~r/.{1,76}/ |> Regex.scan(b64) |> Enum.join("\n")}
          ] do
        %{"attachment" => a} =
          upload!(ctx.conn, %{
            card: ctx.card.id,
            filename: name,
            content_base64: b64,
            sha256: sha256(bytes)
          })

        assert a["size"] == byte_size(bytes)

        %{"content" => [_, %{"type" => "resource", "resource" => %{"blob" => blob}}]} =
          call(ctx.conn, "download_file", %{attachment: a["id"]})

        assert Base.decode64!(blob) == bytes
      end
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
          content_base64: Base.encode64(bytes),
          sha256: sha256(bytes)
        })

      assert a["size"] == 2_000_000
      assert a["content_type"] == "application/octet-stream"
      assert SlipdockWeb.MCP.Plug.max_body() > ceil(UploadFile.max_bytes() * 4 / 3) + 1000
    end
  end

  describe "upload_file from a vault file (#1040)" do
    setup ctx do
      {:ok, vault} = Slipdock.Vaults.create_vault(ctx.user, %{"name" => "Brain1040"})
      {:ok, _} = Slipdock.Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.board})
      bytes = :crypto.strong_rand_bytes(50_000)
      source = Path.join(System.tmp_dir!(), "vault-1040-#{System.unique_integer([:positive])}")
      File.write!(source, bytes)
      on_exit(fn -> File.rm(source) end)

      {:ok, entry} =
        Slipdock.Vaults.Sync.write_file(vault, ctx.user, %{"path" => "Jobs/CV.docx"}, source)

      %{vault: vault, bytes: bytes, entry: entry}
    end

    test "copies it onto a card by its path, byte for byte, under its own name", ctx do
      %{"card" => card_id, "attachment" => a} =
        upload!(ctx.conn, %{card: ctx.card.id, vault: "brain1040", vault_file: "jobs/cv.docx"})

      assert card_id == ctx.card.id
      assert a["filename"] == "CV.docx"
      assert a["size"] == 50_000
      assert a["sha256"] == sha256(ctx.bytes)

      assert a["content_type"] ==
               "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

      [stored] = card_files(ctx.card)
      assert File.read!(Boards.attachment_path(stored)) == ctx.bytes
      # A copy: the vault keeps its file.
      assert {:ok, _, _} =
               Slipdock.Vaults.Sync.read_file(ctx.vault, ctx.user, ctx.entry.id)
    end

    test "or by its id, onto a page, under a name given, with a matching sha256", ctx do
      %{"page" => code, "attachment" => a} =
        upload!(ctx.conn, %{
          page: ctx.page.code,
          vault: "#{ctx.vault.id}",
          vault_file: "#{ctx.entry.id}",
          filename: "David CV.docx",
          sha256: String.upcase(sha256(ctx.bytes))
        })

      assert code == ctx.page.code
      assert a["filename"] == "David CV.docx"
      assert a["sha256"] == sha256(ctx.bytes)
    end

    test "a sha256 the vault's copy doesn't have is refused, and nothing is stored", ctx do
      text =
        ctx.conn
        |> call("upload_file", %{
          card: ctx.card.id,
          vault: "Brain1040",
          vault_file: "Jobs/CV.docx",
          sha256: sha256("another version")
        })
        |> error!()

      assert text =~ "sha256_mismatch: Jobs/CV.docx in the vault has sha256 #{sha256(ctx.bytes)}"
      assert text =~ "Nothing was stored"
      assert card_files(ctx.card) == []
    end

    test "says what is wrong with the arguments, and stores nothing", ctx do
      base = %{card: ctx.card.id, vault: "Brain1040", vault_file: "Jobs/CV.docx"}

      bad = [
        {Map.delete(base, :vault), "vault is required"},
        {%{base | vault: "Nope"}, "no vault \"Nope\""},
        {%{base | vault_file: "Jobs/Missing.docx"}, "file at Jobs/Missing.docx"},
        {%{base | vault_file: "999999999"}, "file 999999999"},
        {%{base | vault_file: "../etc/passwd"}, "hidden files"},
        {Map.put(base, :text, "x"), "vault_file or the content, not both"},
        {Map.put(base, :content_base64, "eA=="), "vault_file or the content, not both"},
        {Map.put(base, :append, true), "copied whole"},
        {Map.delete(base, :card), "card, or page"}
      ]

      for {args, message} <- bad do
        assert ctx.conn |> call("upload_file", args) |> error!() =~ message
      end

      assert card_files(ctx.card) == []
    end

    test "only the caller's own vaults, and only with a token that writes", ctx do
      assert ctx.conn
             |> with_token(ctx.stranger, [])
             |> call("upload_file", %{
               card: ctx.secret.id,
               vault: "Brain1040",
               vault_file: "Jobs/CV.docx"
             })
             |> error!() =~ "no vault"

      assert ctx.conn
             |> with_token(ctx.user, scope: "read")
             |> call("upload_file", %{
               card: ctx.card.id,
               vault: "Brain1040",
               vault_file: "Jobs/CV.docx"
             })
             |> error!() =~ "read-only"

      assert card_files(ctx.card) == []
      assert card_files(ctx.secret) == []
    end

    test "the description sends a caller with a shell to an upload link (#1147)" do
      text = UploadFile.description()
      assert text =~ "link: true"
      assert text =~ "vault_file"
      assert text =~ "sha256 (required"
    end
  end

  describe "upload_file in chunks (#1016)" do
    defp chunk!(conn, args),
      do: conn |> call("upload_file", Map.put(args, :append, true)) |> ok!()

    defp chunk_args(bytes),
      do: %{content_base64: Base.encode64(bytes), sha256: sha256(bytes)}

    test "a 100 KB file arrives in verified chunks; a corrupted one is refused and resent alone",
         ctx do
      file = :crypto.strong_rand_bytes(100_000)
      [first | rest] = for <<c::binary-size(4096) <- file>>, do: c
      tail = binary_part(file, 24 * 4096, 100_000 - 24 * 4096)
      rest = rest ++ [tail]

      %{"upload_id" => id, "received" => 4096} =
        chunk!(
          ctx.conn,
          Map.merge(chunk_args(first), %{card: ctx.card.id, filename: "report.docx"})
        )

      Enum.with_index(rest, 1)
      |> Enum.each(fn {piece, i} ->
        offset = i * 4096

        if i == 10 do
          # The bytes changed on the way; the hash is of what was meant.
          <<b, more::binary>> = piece
          damaged = <<Bitwise.bxor(b, 1)>> <> more

          text =
            ctx.conn
            |> call("upload_file", %{
              upload_id: id,
              append: true,
              offset: offset,
              content_base64: Base.encode64(damaged),
              sha256: sha256(piece)
            })
            |> error!()

          assert text =~ "sha256_mismatch: this chunk arrived"
          assert text =~ "resend just this chunk"
        end

        %{"received" => received} =
          chunk!(ctx.conn, Map.merge(chunk_args(piece), %{upload_id: id, offset: offset}))

        assert received == offset + byte_size(piece)
      end)

      # Every chunk is in, and still nothing shows on the card.
      assert card_files(ctx.card) == []

      %{"card" => card_id, "attachment" => a} =
        upload!(ctx.conn, %{upload_id: id, finish: true, sha256: sha256(file)})

      assert card_id == ctx.card.id
      assert a["filename"] == "report.docx"
      assert a["size"] == 100_000
      assert a["sha256"] == sha256(file)
      [stored] = card_files(ctx.card)
      assert File.read!(Boards.attachment_path(stored)) == file

      # The upload is gone once it is an attachment.
      assert ctx.conn
             |> call("upload_file", %{upload_id: id, finish: true, sha256: sha256(file)})
             |> error!() =~ "unknown_upload"
    end

    test "a resent chunk that already landed isn't added twice; a gap is refused", ctx do
      %{"upload_id" => id} =
        chunk!(ctx.conn, Map.merge(chunk_args("abc"), %{card: ctx.card.id, filename: "a.txt"}))

      second = Map.merge(chunk_args("def"), %{upload_id: id, offset: 3})
      assert %{"received" => 6} = chunk!(ctx.conn, second)
      # The answer was lost, say, and the same chunk comes again.
      assert %{"received" => 6} = chunk!(ctx.conn, second)

      text =
        ctx.conn
        |> call(
          "upload_file",
          Map.merge(chunk_args("xyz"), %{upload_id: id, append: true, offset: 3})
        )
        |> error!()

      assert text =~ "offset_mismatch"
      assert text =~ "has 6 bytes"

      assert ctx.conn
             |> call(
               "upload_file",
               Map.merge(chunk_args("ghi"), %{upload_id: id, append: true, offset: 9})
             )
             |> error!() =~ "offset 6, not 9"

      %{"attachment" => a} =
        upload!(ctx.conn, %{upload_id: id, finish: true, sha256: sha256("abcdef")})

      assert a["size"] == 6
    end

    test "a whole file that doesn't match is refused, and nothing is attached", ctx do
      %{"upload_id" => id} =
        chunk!(ctx.conn, Map.merge(chunk_args("abc"), %{card: ctx.card.id, filename: "a.txt"}))

      # Without offsets, a chunk sent twice goes in twice.
      chunk!(ctx.conn, Map.merge(chunk_args("def"), %{upload_id: id}))
      chunk!(ctx.conn, Map.merge(chunk_args("def"), %{upload_id: id}))

      text =
        ctx.conn
        |> call("upload_file", %{upload_id: id, finish: true, sha256: sha256("abcdef")})
        |> error!()

      assert text =~ "sha256_mismatch"
      assert text =~ "9 bytes"
      assert text =~ "missing or was sent twice"
      assert card_files(ctx.card) == []

      assert ctx.conn
             |> call("upload_file", %{upload_id: id, finish: true, sha256: sha256("abcdefdef")})
             |> error!() =~ "unknown_upload"
    end

    test "goes onto a page too", ctx do
      %{"upload_id" => id} =
        chunk!(ctx.conn, Map.merge(chunk_args("one "), %{page: ctx.page.code, filename: "p.txt"}))

      chunk!(ctx.conn, Map.merge(chunk_args("two"), %{upload_id: id, offset: 4}))
      assert Slipdock.Wiki.attachments(ctx.page) == []

      %{"page" => code, "attachment" => a} =
        upload!(ctx.conn, %{upload_id: id, finish: true, sha256: sha256("one two")})

      assert code == ctx.page.code
      assert a["sha256"] == sha256("one two")
      assert [%{filename: "p.txt"}] = Slipdock.Wiki.attachments(ctx.page)
    end

    test "says what is wrong with the arguments", ctx do
      first = Map.merge(chunk_args("abc"), %{card: ctx.card.id, filename: "a.txt", append: true})
      %{"upload_id" => id} = ctx.conn |> call("upload_file", first) |> ok!()

      bad = [
        {Map.delete(first, :sha256), "each chunk needs its sha256"},
        {Map.put(first, :sha256, "nope"), "64 hex characters"},
        {Map.put(first, :offset, 5), "first chunk starts at offset 0"},
        {Map.put(first, :offset, -1), "offset must be a whole number"},
        {Map.put(first, :finish, true), "not both"},
        {Map.delete(first, :filename), "filename is required"},
        {%{upload_id: id, filename: "a.txt", text: "x"}, "append: true or finish: true"},
        {%{upload_id: id, finish: true}, "finish needs sha256"},
        {%{upload_id: id, finish: true, sha256: sha256("abc"), text: "x"},
         "finish takes no content"},
        {%{finish: true, sha256: sha256("abc")}, "upload_id is required"},
        {Map.merge(chunk_args("x"), %{upload_id: Ecto.UUID.generate(), append: true}),
         "unknown_upload"},
        {Map.merge(chunk_args("x"), %{upload_id: "../../etc/passwd", append: true}),
         "unknown_upload"}
      ]

      for {args, message} <- bad do
        assert ctx.conn |> call("upload_file", args) |> error!() =~ message, inspect(args)
      end

      assert card_files(ctx.card) == []
      # None of that touched the upload.
      assert %{"attachment" => _} =
               upload!(ctx.conn, %{upload_id: id, finish: true, sha256: sha256("abc")})
    end

    test "never starts on a card the token can't write to", ctx do
      assert ctx.conn
             |> call(
               "upload_file",
               Map.merge(chunk_args("x"), %{card: ctx.secret.id, filename: "a.txt", append: true})
             )
             |> error!() =~ "you don't edit this card"
    end

    test "someone else can't add to or finish an upload", ctx do
      %{"upload_id" => id} =
        chunk!(ctx.conn, Map.merge(chunk_args("abc"), %{card: ctx.card.id, filename: "a.txt"}))

      other = conn_as(ctx.stranger)

      assert other
             |> call("upload_file", Map.merge(chunk_args("x"), %{upload_id: id, append: true}))
             |> error!() =~ "unknown_upload"

      assert other
             |> call("upload_file", %{upload_id: id, finish: true, sha256: sha256("abc")})
             |> error!() =~ "unknown_upload"

      assert card_files(ctx.card) == []
    end

    test "finish checks access again: a writer who lost the board can't attach", ctx do
      writer = user_fixture("writer@example.com")
      share_fixture(ctx.board, writer, "write")
      conn = conn_as(writer)

      %{"upload_id" => id} =
        chunk!(conn, Map.merge(chunk_args("abc"), %{card: ctx.card.id, filename: "a.txt"}))

      Slipdock.Access.Grant
      |> Repo.get_by!(user_id: writer.id, board_id: ctx.board.id)
      |> Slipdock.Access.revoke()

      text =
        conn
        |> call("upload_file", %{upload_id: id, finish: true, sha256: sha256("abc")})
        |> error!()

      refute text =~ "unknown_upload"
      assert card_files(ctx.card) == []
    end
  end

  describe "download_file with text: true" do
    test "sends the words read from the file, not the file", ctx do
      Slipdock.TestConfig.put(:ocr, run: fn _, _ -> {"Invoice 42", 0} end)
      a = attach(ctx.card, "scan.png", @png, "image/png")
      Slipdock.OCR.run_next()

      assert %{"status" => "done", "text" => "Invoice 42", "filename" => "scan.png"} =
               ctx.conn
               |> call("download_file", %{attachment: a.id, text: true})
               |> ok!()
    end

    test "says so when there is nothing read", ctx do
      a = attach(ctx.card, "a.txt", "hi", "text/plain")

      assert %{"status" => nil, "text" => ""} =
               ctx.conn
               |> call("download_file", %{attachment: a.id, text: true})
               |> ok!()
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
      assert listed["sha256"] == sha256("on the page")

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

  describe "delete_attachment (#1017)" do
    defp delete_file(conn, id),
      do: call(conn, "delete_attachment", %{attachment: id, confirm: true})

    test "deletes a file just uploaded to a card, by its id, bytes and all", ctx do
      %{"attachment" => %{"id" => id}} =
        upload!(ctx.conn, %{card: ctx.card.id, filename: "bad.docx", text: "corrupt"})

      [stored] = card_files(ctx.card)
      path = Boards.attachment_path(stored)
      assert File.exists?(path)

      assert %{"deleted" => true, "attachment" => ^id, "filename" => "bad.docx", "card" => card} =
               ctx.conn |> delete_file(id) |> ok!()

      assert card == ctx.card.id
      assert card_files(ctx.card) == []
      refute File.exists?(path)
      assert ctx.conn |> delete_file(id) |> error!() =~ "no attachment you can see"
    end

    test "deletes a page's file", ctx do
      %{"attachment" => %{"id" => id}} =
        upload!(ctx.conn, %{page: ctx.page.code, filename: "a.txt", text: "one"})

      assert %{"page" => code} = ctx.conn |> delete_file(id) |> ok!()
      assert code == ctx.page.code
      assert Slipdock.Wiki.attachments(ctx.page) == []
    end

    test "wants confirm: true, and a real id", ctx do
      a = attach(ctx.card, "k.txt", "keep", "text/plain")

      assert ctx.conn |> call("delete_attachment", %{attachment: a.id}) |> error!() =~ "confirm"

      assert ctx.conn
             |> call("delete_attachment", %{attachment: a.id, confirm: false})
             |> error!() =~ "confirm"

      assert ctx.conn |> call("delete_attachment", %{confirm: true}) |> error!() =~
               "attachment is required"

      assert ctx.conn |> delete_file("x") |> error!() =~ "like 42"
      assert ctx.conn |> delete_file(999_999) |> error!() =~ "no attachment you can see"
      assert [_] = card_files(ctx.card)
    end

    test "a stranger's file is not there, and a reader may not delete", ctx do
      theirs = attach(ctx.secret, "s.txt", "secret", "text/plain")
      assert ctx.conn |> delete_file(theirs.id) |> error!() =~ "no attachment you can see"
      assert [_] = card_files(ctx.secret)

      mine = attach(ctx.card, "m.txt", "mine", "text/plain")
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")
      text = conn_as(reader) |> delete_file(mine.id) |> error!()
      refute text =~ "no attachment"
      assert [_] = card_files(ctx.card)
    end

    test "a read-only token is refused", ctx do
      a = attach(ctx.card, "k.txt", "keep", "text/plain")

      assert ctx.conn
             |> with_token(ctx.user, scope: "read")
             |> delete_file(a.id)
             |> error!() =~ "read-only"

      assert [_] = card_files(ctx.card)
    end

    test "is listed as destructive" do
      tool = SlipdockWeb.MCP.Tools.find("delete_attachment")
      assert SlipdockWeb.MCP.Tools.describe(tool).annotations.destructiveHint == true
    end
  end

  describe "upload_file replace: true (#1017)" do
    test "a rebuild under the same name leaves exactly one current file", ctx do
      %{"attachment" => %{"id" => first}} =
        upload!(ctx.conn, %{card: ctx.card.id, filename: "out.docx", text: "build 1"})

      %{"attachment" => %{"id" => second}} =
        upload!(ctx.conn, %{card: ctx.card.id, filename: "out.docx", text: "build 2"})

      other = attach(ctx.card, "other.txt", "stays", "text/plain")

      # Without replace, the old way: a second copy, and no replaced key.
      assert length(card_files(ctx.card)) == 3

      %{"attachment" => %{"id" => third}} =
        answer =
        upload!(ctx.conn, %{
          card: ctx.card.id,
          filename: "out.docx",
          text: "build 3",
          replace: true
        })

      assert answer["replaced"] == [first, second]
      assert answer["card"] == ctx.card.id
      files = card_files(ctx.card)
      assert files |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([other.id, third])
      current = Enum.find(files, &(&1.id == third))
      assert File.read!(Boards.attachment_path(current)) == "build 3"
    end

    test "with nothing to replace, replaced is empty", ctx do
      assert %{"replaced" => []} =
               upload!(ctx.conn, %{
                 card: ctx.card.id,
                 filename: "new.txt",
                 text: "x",
                 replace: true
               })

      refute Map.has_key?(
               upload!(ctx.conn, %{card: ctx.card.id, filename: "n2.txt", text: "x"}),
               "replaced"
             )
    end

    test "only touches the same card or page", ctx do
      other_card = card_fixture(hd(ctx.board.columns), %{"title" => "Other"})
      elsewhere = attach(other_card, "out.txt", "elsewhere", "text/plain")
      on_page = upload!(ctx.conn, %{page: ctx.page.code, filename: "out.txt", text: "page"})

      %{"replaced" => []} =
        upload!(ctx.conn, %{card: ctx.card.id, filename: "out.txt", text: "x", replace: true})

      assert [%{id: id}] = card_files(other_card)
      assert id == elsewhere.id

      %{"replaced" => replaced} =
        upload!(ctx.conn, %{page: ctx.page.code, filename: "out.txt", text: "y", replace: true})

      assert replaced == [on_page["attachment"]["id"]]
      assert [%{filename: "out.txt"}] = Slipdock.Wiki.attachments(ctx.page)
    end

    test "a refused upload keeps the old file", ctx do
      old = attach(ctx.card, "out.txt", "good", "text/plain")

      assert ctx.conn
             |> call("upload_file", %{
               card: ctx.card.id,
               filename: "out.txt",
               text: "bad",
               sha256: sha256("other"),
               replace: true
             })
             |> error!() =~ "sha256_mismatch"

      assert ctx.conn
             |> call("upload_file", %{
               card: ctx.card.id,
               filename: "out.txt",
               text: "x",
               replace: "yes"
             })
             |> error!() =~ "replace must be true or false"

      assert [%{id: id}] = card_files(ctx.card)
      assert id == old.id
    end

    test "said on the first chunk or on finish, a chunked upload replaces too", ctx do
      for {start_args, finish_args} <- [{%{replace: true}, %{}}, {%{}, %{replace: true}}] do
        attach(ctx.card, "big.bin", "old", "application/octet-stream")
        before = ctx.card |> card_files() |> Enum.map(& &1.id) |> Enum.sort()
        bytes = :crypto.strong_rand_bytes(5_000)

        %{"upload_id" => uid} =
          chunk!(
            ctx.conn,
            Map.merge(
              %{card: ctx.card.id, filename: "big.bin"},
              Map.merge(chunk_args(bytes), start_args)
            )
          )

        %{"attachment" => %{"id" => new_id}, "replaced" => replaced} =
          upload!(
            ctx.conn,
            Map.merge(%{upload_id: uid, finish: true, sha256: sha256(bytes)}, finish_args)
          )

        assert replaced == before
        assert [%{id: ^new_id}] = card_files(ctx.card)
      end
    end
  end
end
