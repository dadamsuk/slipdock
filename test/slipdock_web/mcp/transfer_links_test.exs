defmodule SlipdockWeb.MCP.TransferLinksTest do
  @moduledoc """
  Short-lived, single-use upload and download links (#1147): `upload_file`
  and `download_file` with `link: true` hand out a URL a shell can curl
  without a token, which reaches one card, page or attachment, works once,
  expires, and is checked as the token that made it at the moment it is used.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Repo, TransferLinks, Wiki}
  alias Slipdock.TransferLinks.Link

  setup %{user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Links", "code" => "xfer1147"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Gets a CV"})
    page = page_fixture(board, %{"title" => "Style", "body" => "# Style"}, user: user)

    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirsxfer"}, owner: stranger)
    secret_card = card_fixture(hd(theirs.columns), %{"title" => "Their card"})

    %{board: board, card: card, page: page, stranger: stranger, secret_card: secret_card}
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

  defp path_of(url), do: URI.parse(url).path

  defp file(bytes, name \\ "cv.docx") do
    path = Path.join(System.tmp_dir!(), "xfer-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: name, content_type: "application/octet-stream"}
  end

  # Straight from a shell: no session, no token.
  defp curl_post(url, fields), do: post(build_conn(), path_of(url), fields)
  defp curl_get(url), do: get(build_conn(), path_of(url))

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp card_files(card),
    do: Repo.preload(Boards.get_card!(card.id), :attachments, force: true).attachments

  defp upload_link!(conn, args),
    do: conn |> call("upload_file", Map.put(args, :link, true)) |> ok!()

  describe "upload_file link: true" do
    test "gives a URL that attaches the file to the card, without a token, once", ctx do
      answer = upload_link!(ctx.conn, %{card: ctx.card.id})

      assert answer["card"] == ctx.card.id
      assert answer["method"] == "POST"
      assert answer["upload_url"] =~ ~r"/api/upload/[\w-]{40,}\z"
      assert answer["curl"] =~ "-F file=@<path>"
      assert answer["curl"] =~ answer["upload_url"]
      {:ok, expires, _} = DateTime.from_iso8601(answer["expires_at"])
      assert DateTime.diff(expires, DateTime.utc_now()) in 590..600

      bytes = :crypto.strong_rand_bytes(50_000)

      conn =
        curl_post(answer["upload_url"], %{
          "file" => file(bytes),
          "sha256" => sha256(bytes),
          "filename" => "David CV.docx",
          "hide_on_card" => "true"
        })

      assert %{"attachment" => a} = json_response(conn, 201)
      assert a["filename"] == "David CV.docx"
      assert a["sha256"] == sha256(bytes)
      assert a["size"] == 50_000
      assert a["hide_on_card"] == true
      assert a["markdown"] =~ "David CV.docx"

      [stored] = card_files(ctx.card)
      assert stored.id == a["id"]
      assert File.read!(Boards.attachment_path(stored)) == bytes

      again = curl_post(answer["upload_url"], %{"file" => file("more")})
      assert json_response(again, 410)["error"] =~ "link_gone"
      assert length(card_files(ctx.card)) == 1
    end

    test "on a page, with replace: true leaving one copy", ctx do
      first = upload_link!(ctx.conn, %{page: ctx.page.code})
      assert first["page"] == ctx.page.code
      assert json_response(curl_post(first["upload_url"], %{"file" => file("v1")}), 201)

      second = upload_link!(ctx.conn, %{page: ctx.page.code})

      answer =
        second["upload_url"]
        |> curl_post(%{"file" => file("v2"), "replace" => "true"})
        |> json_response(201)

      assert [_old_id] = answer["replaced"]
      [only] = Wiki.attachments(ctx.page)
      assert File.read!(Boards.attachment_path(only)) == "v2"
    end

    test "a refused upload stores nothing and leaves the link good for a fixed retry", ctx do
      %{"upload_url" => url} = upload_link!(ctx.conn, %{card: ctx.card.id})

      wrong = curl_post(url, %{"file" => file("right"), "sha256" => sha256("wrong")})
      assert json_response(wrong, 422)["error"] =~ "sha256_mismatch"

      missing = curl_post(url, %{"sha256" => sha256("right")})
      assert json_response(missing, 422)["error"] =~ "multipart form field `file`"

      assert card_files(ctx.card) == []

      fixed = curl_post(url, %{"file" => file("right"), "sha256" => sha256("right")})
      assert json_response(fixed, 201)
      assert length(card_files(ctx.card)) == 1
    end

    test "an expired link, an unknown one and a download link are all gone", ctx do
      %{"upload_url" => url} = upload_link!(ctx.conn, %{card: ctx.card.id})
      past = DateTime.add(DateTime.utc_now(:second), -1)
      Repo.update_all(Link, set: [expires_at: past])

      assert json_response(curl_post(url, %{"file" => file("x")}), 410)

      assert json_response(curl_post("/api/upload/nonsense", %{"file" => file("x")}), 410)

      a = upload_and_get(ctx)

      %{"download_url" => dl} =
        ctx.conn |> call("download_file", %{attachment: a.id, link: true}) |> ok!()

      secret = dl |> path_of() |> Path.basename()
      assert json_response(curl_post("/api/upload/" <> secret, %{"file" => file("x")}), 410)

      assert length(card_files(ctx.card)) == 1
    end

    test "dies with the token that made it", ctx do
      {token, record} = Accounts.create_api_token(ctx.user, "cloud task")
      conn = put_req_header(build_conn(), "authorization", "Bearer " <> token)
      %{"upload_url" => url} = upload_link!(conn, %{card: ctx.card.id})

      Accounts.delete_api_token(ctx.user, record.id)

      assert json_response(curl_post(url, %{"file" => file("x")}), 410)
      assert card_files(ctx.card) == []
    end

    test "checks access again when used: a writer demoted since is refused", ctx do
      writer = user_fixture("writer@example.com")
      share_fixture(ctx.board, writer, "write")
      %{"upload_url" => url} = upload_link!(conn_as(writer), %{card: ctx.card.id})

      {:ok, _} = Access.grant(ctx.board, writer, "read", ctx.user)

      assert json_response(curl_post(url, %{"file" => file("x")}), 403)["error"] =~ "edit"
      assert card_files(ctx.card) == []
    end

    test "needs write: a read-only token, a reader and a stranger's card are refused", ctx do
      {token, _} = Accounts.create_api_token(ctx.user, "ro", scope: "read")
      read_only = put_req_header(build_conn(), "authorization", "Bearer " <> token)

      assert read_only |> call("upload_file", %{card: ctx.card.id, link: true}) |> error!() =~
               "read-only"

      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")

      assert conn_as(reader)
             |> call("upload_file", %{card: ctx.card.id, link: true})
             |> error!() =~ "edit"

      assert ctx.conn
             |> call("upload_file", %{card: ctx.secret_card.id, link: true})
             |> error!() =~ "you don't edit this card"

      assert Repo.aggregate(Link, :count) == 0
    end

    test "says what is wrong with the arguments, and makes no link", ctx do
      assert ctx.conn |> call("upload_file", %{link: true}) |> error!() =~ "card, or page"

      assert ctx.conn
             |> call("upload_file", %{card: ctx.card.id, link: true, filename: "a", text: "x"})
             |> error!() =~ "filename, text go in the POST"

      assert Repo.aggregate(Link, :count) == 0
    end

    test "the description offers it to a caller with a shell" do
      text = SlipdockWeb.MCP.Tools.UploadFile.description()
      assert text =~ "link: true"
      assert text =~ "upload_url"
    end
  end

  defp upload_and_get(ctx) do
    %{"upload_url" => url} = upload_link!(ctx.conn, %{card: ctx.card.id})

    %{"attachment" => %{"id" => id}} =
      url |> curl_post(%{"file" => file("hello")}) |> json_response(201)

    Boards.get_attachment!(id)
  end

  describe "download_file link: true" do
    test "gives a URL that sends the file, without a token, once", ctx do
      a = upload_and_get(ctx)

      answer = ctx.conn |> call("download_file", %{attachment: a.id, link: true}) |> ok!()
      assert answer["id"] == a.id
      assert answer["card"] == ctx.card.id
      assert answer["download_url"] =~ ~r"/api/download/[\w-]{40,}\z"
      assert answer["curl"] == "curl -fsSo cv.docx #{answer["download_url"]}"
      refute Map.has_key?(answer, "text")

      conn = curl_get(answer["download_url"])
      assert response(conn, 200) == "hello"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      assert json_response(curl_get(answer["download_url"]), 410)["error"] =~ "link_gone"
    end

    test "a read-only token may have one; a name with spaces is quoted for the shell", ctx do
      %{"upload_url" => url} = upload_link!(ctx.conn, %{page: ctx.page.code})

      %{"attachment" => %{"id" => id}} =
        url |> curl_post(%{"file" => file("tpl", "It's a template.docx")}) |> json_response(201)

      {token, _} = Accounts.create_api_token(ctx.user, "ro", scope: "read")
      read_only = put_req_header(build_conn(), "authorization", "Bearer " <> token)

      answer = read_only |> call("download_file", %{attachment: id, link: true}) |> ok!()
      assert answer["page"] == ctx.page.code
      assert answer["curl"] =~ ~S{-fsSo 'It'\''s a template.docx' }
      assert response(curl_get(answer["download_url"]), 200) == "tpl"
    end

    test "a stranger's file gets no link", ctx do
      path = Path.join(System.tmp_dir!(), "xfer-theirs-#{System.unique_integer([:positive])}")
      File.write!(path, "private")
      on_exit(fn -> File.rm(path) end)

      {:ok, theirs} =
        Boards.add_attachment(
          ctx.secret_card,
          %{filename: "p.txt", content_type: "text/plain"},
          path
        )

      assert ctx.conn
             |> call("download_file", %{attachment: theirs.id, link: true})
             |> error!() =~ "no attachment"

      assert Repo.aggregate(Link, :count) == 0
    end

    test "checks access again when used, and a missing file leaves the link", ctx do
      reader = user_fixture("reader@example.com")
      {:ok, grant} = Access.grant(ctx.board, reader, "read", ctx.user)
      a = upload_and_get(ctx)

      %{"download_url" => url} =
        conn_as(reader) |> call("download_file", %{attachment: a.id, link: true}) |> ok!()

      Access.revoke(grant)
      assert json_response(curl_get(url), 404)

      %{"download_url" => url} =
        ctx.conn |> call("download_file", %{attachment: a.id, link: true}) |> ok!()

      File.rm!(Boards.attachment_path(a))
      assert json_response(curl_get(url), 404)["error"] =~ "the file's bytes"
      File.write!(Boards.attachment_path(a), "hello")
      assert response(curl_get(url), 200) == "hello"
    end
  end

  describe "TransferLinks" do
    test "keeps only the hash of the secret, and sweeps expired links when making one", ctx do
      token = Repo.one!(from(t in Accounts.UserToken, where: t.user_id == ^ctx.user.id, limit: 1))
      {:ok, old, _} = TransferLinks.mint(ctx.user, token, {:card, ctx.card})
      refute Repo.exists?(from(l in Link, where: l.token_hash == ^old))

      Repo.update_all(Link, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])
      {:ok, _new, _} = TransferLinks.mint(ctx.user, token, {:page, ctx.page})

      assert [%Link{kind: "upload", page_id: page_id}] = Repo.all(Link)
      assert page_id == ctx.page.id
      assert TransferLinks.claim(old, "upload") == {:error, :gone}
      assert TransferLinks.claim(nil, "upload") == {:error, :gone}
    end
  end
end
