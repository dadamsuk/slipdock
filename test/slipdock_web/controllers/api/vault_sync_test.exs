defmodule SlipdockWeb.API.VaultSyncTest do
  @moduledoc "`/api/vaults/:id/sync`: the vault as files over HTTP, for `slipdock sync`."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Quota, Repo, Vaults, Wiki}
  alias Slipdock.Wiki.{Files, Page, WikiFile}

  setup %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kb6"}, owner: user)
    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Brain"})
    %{conn: put_req_header(conn, "accept", "application/json"), kb: kb, vault: vault}
  end

  test "list, read, write, conflict and archive, by path and hash", %{conn: conn, kb: kb} do
    {:ok, page} = Wiki.create_page(kb, %{"title" => "Note", "body" => "one"})

    listing = conn |> get("/api/vaults/Brain/sync") |> json_response(200)
    assert is_integer(listing["cursor"])

    assert [%{"kind" => "page", "id" => id, "path" => "Keystone/Note.md", "hash" => hash}] =
             listing["entries"]

    assert id == page.id

    assert %{"page" => %{"content" => "one", "hash" => ^hash}} =
             conn |> get("/api/vaults/Brain/sync/pages/#{page.id}") |> json_response(200)

    created =
      conn
      |> put("/api/vaults/Brain/sync/pages", %{
        "path" => "Keystone/Ideas/New.md",
        "content" => "fresh"
      })
      |> json_response(200)

    assert %{"page" => %{"path" => "Keystone/Ideas/New.md", "title" => "New"}} = created

    edited =
      conn
      |> put("/api/vaults/Brain/sync/pages/#{page.id}", %{
        "path" => "Keystone/Note.md",
        "content" => "two",
        "base" => hash
      })
      |> json_response(200)

    assert Repo.get!(Page, page.id).body == "two"

    conflict =
      conn
      |> put("/api/vaults/Brain/sync/pages/#{page.id}", %{
        "path" => "Keystone/Note.md",
        "content" => "three",
        "base" => hash
      })
      |> json_response(409)

    assert conflict["current"]["content"] == "two"
    assert conflict["current"]["hash"] == edited["page"]["hash"]

    assert conn
           |> delete("/api/vaults/Brain/sync/pages/#{page.id}?base=#{hash}")
           |> json_response(409)

    assert %{"page" => %{"archived" => true}} =
             conn
             |> delete("/api/vaults/Brain/sync/pages/#{page.id}?base=#{edited["page"]["hash"]}")
             |> json_response(200)

    assert Repo.get!(Page, page.id).archived_at
  end

  test "a path in no board, at the root, or one that climbs, is refused", %{conn: conn} do
    assert conn
           |> put("/api/vaults/Brain/sync/pages", %{"path" => "Nowhere/x.md", "content" => "x"})
           |> json_response(422)

    assert conn
           |> put("/api/vaults/Brain/sync/pages", %{"path" => "x.md", "content" => "x"})
           |> json_response(422)

    assert conn
           |> put("/api/vaults/Brain/sync/pages", %{
             "path" => "Keystone/../x.md",
             "content" => "x"
           })
           |> json_response(422)

    assert conn |> get("/api/vaults/Brain/sync/pages/nope") |> json_response(400)
  end

  test "somebody else's vault is not found", %{conn: conn} do
    stranger = user_fixture("stranger@example.com")
    {:ok, theirs} = stranger |> Vaults.root() |> Vaults.update_vault(%{"name" => "Theirs"})
    assert conn |> get("/api/vaults/#{theirs.id}/sync") |> json_response(404)
  end

  test "a read-only token lists and reads but writes nothing", %{user: user, kb: kb} do
    {:ok, page} = Wiki.create_page(kb, %{"title" => "Note", "body" => "one"})
    {token, _} = Accounts.create_api_token(user, "reader", scope: "read")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    assert [_] =
             conn |> get("/api/vaults/Brain/sync") |> json_response(200) |> Map.fetch!("entries")

    assert conn
           |> put("/api/vaults/Brain/sync/pages/#{page.id}", %{
             "path" => "Keystone/Note.md",
             "content" => "x"
           })
           |> json_response(403)

    assert Repo.get!(Page, page.id).body == "one"
  end

  describe "files" do
    defp upload(bytes, name) do
      path = Path.join(System.tmp_dir!(), "up-#{System.unique_integer([:positive])}")
      File.write!(path, bytes)
      %Plug.Upload{path: path, filename: name, content_type: "application/octet-stream"}
    end

    test "post, list, fetch, move, replace and archive a file", %{conn: conn} do
      created =
        conn
        |> post("/api/vaults/Brain/sync/files", %{
          "path" => "Keystone/Img/a.png",
          "file" => upload("png", "Keystone/a.png")
        })
        |> json_response(200)
        |> Map.fetch!("file")

      assert %{"kind" => "file", "path" => "Keystone/Img/a.png", "size" => 3, "hash" => hash} =
               created

      assert [%{"kind" => "file", "id" => id}] =
               conn
               |> get("/api/vaults/Brain/sync")
               |> json_response(200)
               |> Map.fetch!("entries")

      fetched = conn |> get("/api/vaults/Brain/sync/files/#{id}")
      assert fetched.status == 200
      assert fetched.resp_body == "png"
      assert get_resp_header(fetched, "x-slipdock-hash") == [hash]

      moved =
        conn
        |> patch("/api/vaults/Brain/sync/files/#{id}", %{
          "path" => "Keystone/b.png",
          "base" => hash
        })
        |> json_response(200)

      assert moved["file"]["path"] == "Keystone/b.png"

      replaced =
        conn
        |> post("/api/vaults/Brain/sync/files/#{id}", %{
          "path" => "Keystone/b.png",
          "base" => hash,
          "file" => upload("png2", "Keystone/b.png")
        })
        |> json_response(200)

      assert replaced["file"]["size"] == 4

      assert conn
             |> post("/api/vaults/Brain/sync/files/#{id}", %{
               "path" => "Keystone/b.png",
               "base" => hash,
               "file" => upload("png3", "Keystone/b.png")
             })
             |> json_response(409)

      assert conn
             |> delete("/api/vaults/Brain/sync/files/#{id}?base=#{replaced["file"]["hash"]}")
             |> json_response(200)

      assert conn |> get("/api/vaults/Brain/sync/files/#{id}") |> json_response(404)
    end

    defp posted(conn, path \\ "Keystone/a.pdf") do
      conn
      |> post("/api/vaults/Brain/sync/files", %{
        "path" => path,
        "file" => upload("pdf bytes", Path.basename(path))
      })
      |> json_response(200)
      |> Map.fetch!("file")
    end

    defp with_token(user, opts) do
      {token, _} = Accounts.create_api_token(user, "purge", opts)

      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
    end

    test "purge=true deletes a file for its owner, bytes and all", %{conn: conn, user: user} do
      %{"id" => id, "hash" => hash} = posted(conn)
      file = Repo.get!(WikiFile, id)
      assert Quota.used(user, :storage) == byte_size("pdf bytes")

      assert %{"file" => %{"id" => ^id, "deleted" => true}} =
               conn
               |> delete("/api/vaults/Brain/sync/files/#{id}?purge=true&base=#{hash}")
               |> json_response(200)

      refute Repo.get(WikiFile, id)
      refute File.exists?(Files.disk_path(file))
      assert Quota.used(user, :storage) == 0
      assert %{"entries" => []} = conn |> get("/api/vaults/Brain/sync") |> json_response(200)
    end

    test "without purge a file is only archived", %{conn: conn} do
      %{"id" => id} = posted(conn)
      file = Repo.get!(WikiFile, id)

      for query <- ["", "?purge=false"] do
        Repo.update!(Ecto.Changeset.change(Repo.get!(WikiFile, id), archived_at: nil))

        assert %{"file" => %{"id" => ^id, "archived" => true}} =
                 conn
                 |> delete("/api/vaults/Brain/sync/files/#{id}#{query}")
                 |> json_response(200)

        assert Repo.get!(WikiFile, id).archived_at
      end

      assert File.exists?(Files.disk_path(file))
    end

    test "a board shared with the caller is no part of their vault", %{conn: conn, user: user} do
      owner = user_fixture("purge-owner@example.com")
      shared = board_fixture(%{"name" => "Shared", "code" => "kb6s"}, owner: owner)
      {:ok, _} = Access.grant(shared, user, "write", owner)

      source = Path.join(System.tmp_dir!(), "purge-#{System.unique_integer([:positive])}")
      File.write!(source, "bytes")
      on_exit(fn -> File.rm(source) end)
      {:ok, file} = Files.create(shared, %{name: "a.pdf", folder_id: nil}, source, owner)

      assert conn
             |> post("/api/vaults/Brain/sync/files", %{
               "path" => "Shared/a.pdf",
               "file" => upload("pdf bytes", "a.pdf")
             })
             |> json_response(422)

      assert conn
             |> delete("/api/vaults/Brain/sync/files/#{file.id}?purge=true")
             |> json_response(404)

      assert Repo.get!(WikiFile, file.id).archived_at == nil
    end

    test "the owner's read-only token can't purge", %{conn: conn, user: user} do
      %{"id" => id} = posted(conn)

      assert user
             |> with_token(scope: "read")
             |> delete("/api/vaults/Brain/sync/files/#{id}?purge=true")
             |> json_response(403)

      assert Repo.get!(WikiFile, id).archived_at == nil
    end

    test "a stale base refuses a purge and shows the file as it stands", %{conn: conn} do
      %{"id" => id, "hash" => hash} = posted(conn)

      assert %{"current" => %{"hash" => ^hash}} =
               conn
               |> delete("/api/vaults/Brain/sync/files/#{id}?purge=true&base=stale")
               |> json_response(409)

      assert Repo.get(WikiFile, id)
    end

    test "a post without the file is a bad request", %{conn: conn} do
      assert conn
             |> post("/api/vaults/Brain/sync/files", %{"path" => "Keystone/a.png"})
             |> json_response(400)
    end
  end
end
