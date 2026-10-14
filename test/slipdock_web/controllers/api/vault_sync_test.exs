defmodule SlipdockWeb.API.VaultSyncTest do
  @moduledoc "`/api/vaults/:id/sync`: the vault as files over HTTP, for `slipdock sync`."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo, Vaults, Wiki}
  alias Slipdock.Wiki.Page

  setup %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kb"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    %{conn: put_req_header(conn, "accept", "application/json"), kb: kb, vault: vault}
  end

  test "list, read, write, conflict and archive, by path and hash", %{conn: conn, kb: kb} do
    {:ok, page} = Wiki.create_page(kb, %{"title" => "Note", "body" => "one"})

    listing = conn |> get("/api/vaults/Brain/sync") |> json_response(200)
    assert is_integer(listing["cursor"])

    assert [%{"kind" => "page", "id" => id, "path" => "Note.md", "hash" => hash}] =
             listing["entries"]

    assert id == page.id

    assert %{"page" => %{"content" => "one", "hash" => ^hash}} =
             conn |> get("/api/vaults/Brain/sync/pages/#{page.id}") |> json_response(200)

    created =
      conn
      |> put("/api/vaults/Brain/sync/pages", %{"path" => "Ideas/New.md", "content" => "fresh"})
      |> json_response(200)

    assert %{"page" => %{"path" => "Ideas/New.md", "title" => "New"}} = created

    edited =
      conn
      |> put("/api/vaults/Brain/sync/pages/#{page.id}", %{
        "path" => "Note.md",
        "content" => "two",
        "base" => hash
      })
      |> json_response(200)

    assert Repo.get!(Page, page.id).body == "two"

    conflict =
      conn
      |> put("/api/vaults/Brain/sync/pages/#{page.id}", %{
        "path" => "Note.md",
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

  test "a path nothing is mapped at, or one that climbs, is refused", %{conn: conn, user: user} do
    {:ok, _} = Vaults.create_vault(user, %{"name" => "Empty"})

    assert conn
           |> put("/api/vaults/Empty/sync/pages", %{"path" => "x.md", "content" => "x"})
           |> json_response(422)

    assert conn
           |> put("/api/vaults/Brain/sync/pages", %{"path" => "../x.md", "content" => "x"})
           |> json_response(422)

    assert conn |> get("/api/vaults/Brain/sync/pages/nope") |> json_response(400)
  end

  test "somebody else's vault is not found", %{conn: conn} do
    stranger = user_fixture("stranger@example.com")
    {:ok, theirs} = Vaults.create_vault(stranger, %{"name" => "Theirs"})
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
             "path" => "Note.md",
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
          "path" => "Img/a.png",
          "file" => upload("png", "a.png")
        })
        |> json_response(200)
        |> Map.fetch!("file")

      assert %{"kind" => "file", "path" => "Img/a.png", "size" => 3, "hash" => hash} = created

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
        |> patch("/api/vaults/Brain/sync/files/#{id}", %{"path" => "b.png", "base" => hash})
        |> json_response(200)

      assert moved["file"]["path"] == "b.png"

      replaced =
        conn
        |> post("/api/vaults/Brain/sync/files/#{id}", %{
          "path" => "b.png",
          "base" => hash,
          "file" => upload("png2", "b.png")
        })
        |> json_response(200)

      assert replaced["file"]["size"] == 4

      assert conn
             |> post("/api/vaults/Brain/sync/files/#{id}", %{
               "path" => "b.png",
               "base" => hash,
               "file" => upload("png3", "b.png")
             })
             |> json_response(409)

      assert conn
             |> delete("/api/vaults/Brain/sync/files/#{id}?base=#{replaced["file"]["hash"]}")
             |> json_response(200)

      assert conn |> get("/api/vaults/Brain/sync/files/#{id}") |> json_response(404)
    end

    test "a post without the file is a bad request", %{conn: conn} do
      assert conn
             |> post("/api/vaults/Brain/sync/files", %{"path" => "a.png"})
             |> json_response(400)
    end
  end
end
