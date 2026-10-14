defmodule SlipdockWeb.API.VaultsTest do
  @moduledoc "`/api/vaults`: making, mapping, locating and deleting a vault over HTTP."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}

  setup %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kb5"}, owner: user)
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobs4"}, owner: user)
    {:ok, _} = Wiki.create_folder(jobs, %{"name" => "Notes"})
    %{conn: put_req_header(conn, "accept", "application/json"), kb: kb, jobs: jobs}
  end

  defp make(conn, name),
    do:
      conn |> post("/api/vaults", %{"name" => name}) |> json_response(201) |> Map.fetch!("vault")

  test "the whole road: make, map, show, locate, unmap, rename, delete", %{conn: conn} do
    assert make(conn, "Notes")["mappings"] == []

    conn |> post("/api/vaults/Notes/mappings", %{"board" => "kb5"}) |> json_response(201)

    vault =
      conn
      |> post("/api/vaults/notes/mappings", %{
        "path" => "/Journal",
        "board" => "jobs4",
        "folder" => "Notes"
      })
      |> json_response(201)
      |> Map.fetch!("vault")

    assert [%{"path" => "/", "folder" => nil}, %{"path" => "/Journal"} = jobs] = vault["mappings"]
    assert jobs["board"]["code"] == "jobs4"
    assert jobs["folder"]["path"] == "Notes"

    assert [%{"name" => "Notes"}] =
             conn |> get("/api/vaults") |> json_response(200) |> Map.fetch!("vaults")

    assert %{"vault" => %{"id" => id}} = conn |> get("/api/vaults/Notes") |> json_response(200)

    located =
      conn |> get("/api/vaults/#{id}/locate?path=/Journal/Acme/Call.md") |> json_response(200)

    assert located["mapping"]["path"] == "/Journal"
    assert located["rest"] == "Acme/Call.md"

    after_unmap =
      conn
      |> delete("/api/vaults/Notes/mappings?path=/Journal")
      |> json_response(200)
      |> Map.fetch!("vault")

    assert [%{"path" => "/"} = root] = after_unmap["mappings"]

    assert conn |> delete("/api/vaults/Notes/mappings/#{root["id"]}") |> json_response(200)

    assert %{"vault" => %{"name" => "Brain"}} =
             conn |> patch("/api/vaults/Notes", %{"name" => "Brain"}) |> json_response(200)

    assert %{"deleted" => %{"name" => "Brain"}} =
             conn |> delete("/api/vaults/Brain") |> json_response(200)

    assert conn |> get("/api/vaults/Brain") |> json_response(404)
  end

  test "refusals say why", %{conn: conn, user: user} do
    make(conn, "Notes")

    assert conn |> post("/api/vaults", %{"name" => "notes"}) |> json_response(422)
    assert conn |> post("/api/vaults/Notes/mappings", %{"board" => "nope"}) |> json_response(404)

    assert conn
           |> post("/api/vaults/Notes/mappings", %{"board" => "jobs4", "folder" => "Missing"})
           |> json_response(404)

    assert conn |> get("/api/vaults/Notes/locate?path=/x.md") |> json_response(404)

    assert %{"error" => error} =
             conn |> delete("/api/vaults/Notes/mappings") |> json_response(400)

    assert error =~ "mapping"

    # A board you can only read cannot go into your vault.
    owner = user_fixture("someone@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs3"}, owner: owner)
    share_fixture(theirs, user, "read")

    assert %{"error" => forbidden} =
             conn
             |> post("/api/vaults/Notes/mappings", %{"board" => "theirs3"})
             |> json_response(403)

    assert forbidden =~ "edit"
  end

  test "somebody else's vault is not there", %{user: user} do
    stranger = user_fixture("stranger@example.com")
    {:ok, vault} = Vaults.create_vault(stranger, %{"name" => "Private"})

    conn = conn_as(user) |> put_req_header("accept", "application/json")
    assert conn |> get("/api/vaults/#{vault.id}") |> json_response(404)
    assert conn |> delete("/api/vaults/#{vault.id}") |> json_response(404)
    assert Vaults.get_vault(stranger, vault.id) |> elem(0) == :ok
  end

  test "a read-only token reads vaults and changes none", %{user: user} do
    {:ok, _} = Vaults.create_vault(user, %{"name" => "Notes"})
    {token, _} = Accounts.create_api_token(user, "reader", scope: "read")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    assert conn |> get("/api/vaults") |> json_response(200)
    assert conn |> post("/api/vaults", %{"name" => "More"}) |> json_response(403)
  end

  test "resolve a link and list what is wanted, across the vault", %{
    conn: conn,
    user: user,
    kb: kb,
    jobs: jobs
  } do
    make(conn, "Notes")
    conn |> post("/api/vaults/Notes/mappings", %{"board" => "kb5"}) |> json_response(201)

    conn
    |> post("/api/vaults/Notes/mappings", %{"path" => "/Journal", "board" => "jobs4"})
    |> json_response(201)

    {:ok, note} = Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)

    {:ok, _} =
      Wiki.create_page(kb, %{"title" => "Linker", "body" => "[[Acme]] [[Ghost]]"}, user: user)

    found = conn |> get("/api/vaults/Notes/resolve?link=Journal/Acme") |> json_response(200)
    assert found["page"]["code"] == note.code
    assert found["path"] == "/Journal/Acme"

    assert conn |> get("/api/vaults/Notes/resolve?link=Nope") |> json_response(404)
    assert conn |> get("/api/vaults/Notes/resolve") |> json_response(400)

    assert [%{"title" => "Ghost", "from" => [%{"title" => "Linker"}]}] =
             conn |> get("/api/vaults/Notes/wanted") |> json_response(200) |> Map.fetch!("wanted")
  end

  test "the change feed: a cursor to start from, then what changed", %{
    conn: conn,
    user: user,
    kb: kb
  } do
    make(conn, "Notes")
    conn |> post("/api/vaults/Notes/mappings", %{"board" => "kb5"}) |> json_response(201)

    %{"changes" => [], "cursor" => start} =
      conn |> get("/api/vaults/Notes/changes") |> json_response(200)

    {:ok, page} = Wiki.create_page(kb, %{"title" => "Fresh"}, user: user)

    body = conn |> get("/api/vaults/Notes/changes?since=#{start}") |> json_response(200)

    assert [%{"subject" => "page", "id" => id, "path" => "/Fresh", "action" => "changed"}] =
             body["changes"]

    assert id == page.id
    assert body["more"] == false

    assert conn |> get("/api/vaults/Notes/changes?since=-1") |> json_response(400)
    assert conn |> get("/api/vaults/Notes/changes?since=x") |> json_response(400)
    assert conn |> get("/api/vaults/Elsewhere/changes") |> json_response(404)
  end

  test "a vault shows each mapping's page count and the tokens that synced it", ctx do
    %{conn: conn, kb: kb} = ctx
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Note"})
    make(conn, "Brain")
    conn |> post("/api/vaults/Brain/mappings", %{"board" => "kb5"}) |> json_response(201)

    shown = conn |> get("/api/vaults/Brain") |> json_response(200) |> Map.fetch!("vault")
    assert [%{"path" => "/", "pages" => 1}] = shown["mappings"]
    # Its own view in the web app (#752).
    assert shown["url"] == "/vaults/Brain"
    assert shown["mirrors"] == []

    # Listing it for a sync, or following its feed, marks the token a mirror.
    conn |> get("/api/vaults/Brain/sync") |> json_response(200)
    conn |> get("/api/vaults/Brain/changes") |> json_response(200)

    shown = conn |> get("/api/vaults/Brain") |> json_response(200) |> Map.fetch!("vault")
    assert [%{"label" => "test", "last_synced_at" => _}] = shown["mirrors"]

    # Deleting answers with what it held, counts and all.
    deleted = conn |> delete("/api/vaults/Brain") |> json_response(200) |> Map.fetch!("deleted")
    assert [%{"pages" => 1}] = deleted["mappings"]
  end

  test "dry_run previews a mapping and its removal, and changes nothing", ctx do
    %{conn: conn, jobs: jobs} = ctx
    {:ok, _} = Wiki.create_page(jobs, %{"title" => "Acme"})
    make(conn, "Brain")

    preview =
      conn
      |> post("/api/vaults/Brain/mappings", %{
        "path" => "/Journal",
        "board" => "jobs4",
        "dry_run" => true
      })
      |> json_response(200)

    assert preview["dry_run"]
    assert preview["preview"]["arriving"] == %{"count" => 1, "sample" => ["Journal/Acme.md"]}

    assert conn |> get("/api/vaults/Brain") |> json_response(200) |> get_in(["vault", "mappings"]) ==
             []

    conn
    |> post("/api/vaults/Brain/mappings", %{"path" => "/Journal", "board" => "jobs4"})
    |> json_response(201)

    out =
      conn
      |> delete("/api/vaults/Brain/mappings?path=/Journal&dry_run=true")
      |> json_response(200)

    assert out["preview"]["leaving"]["sample"] == ["Journal/Acme.md"]

    assert [_] =
             conn
             |> get("/api/vaults/Brain")
             |> json_response(200)
             |> get_in(["vault", "mappings"])

    # A refusal is the same refusal as the real thing.
    conn
    |> post("/api/vaults/Brain/mappings", %{
      "path" => "/Journal",
      "board" => "kb5",
      "dry_run" => true
    })
    |> json_response(422)
  end

  test "a mapping over pages another board has there is a 422 with the count", ctx do
    %{conn: conn, kb: kb} = ctx
    {:ok, jobs} = Wiki.create_folder(kb, %{"name" => "Journal"})
    {:ok, _} = Wiki.create_page(kb, %{"title" => "Acme", "folder_id" => jobs.id})
    make(conn, "Brain")
    conn |> post("/api/vaults/Brain/mappings", %{"board" => "kb5"}) |> json_response(201)

    for dry_run <- [false, true] do
      error =
        conn
        |> post("/api/vaults/Brain/mappings", %{
          "path" => "/Journal",
          "board" => "jobs4",
          "dry_run" => dry_run
        })
        |> json_response(422)
        |> inspect()

      assert error =~ "would overlap 1 page Keystone already has under /Journal"
    end

    assert conn |> get("/api/vaults/Brain") |> json_response(200) |> get_in(["vault", "overlaps"]) ==
             []
  end

  describe "split" do
    setup %{conn: conn, kb: kb} do
      {:ok, folder} = Wiki.create_folder(kb, %{"name" => "Work"})
      {:ok, page} = Wiki.create_page(kb, %{"title" => "Acme", "folder_id" => folder.id})
      make(conn, "Brain")
      conn |> post("/api/vaults/Brain/mappings", %{"board" => "kb5"}) |> json_response(201)
      %{page: page}
    end

    test "dry_run previews, then it moves the folder's contents and maps the path", ctx do
      %{conn: conn, jobs: jobs, page: page} = ctx

      dry =
        conn
        |> post("/api/vaults/Brain/split", %{
          "path" => "/Work",
          "board" => "jobs4",
          "dry_run" => true
        })
        |> json_response(200)

      assert %{"path" => "/Work", "into" => "Journal Desk", "unchanged" => 1} = dry["preview"]
      assert Wiki.get_page!(page.id).board_id != jobs.id

      done =
        conn
        |> post("/api/vaults/Brain/split", %{"path" => "/Work", "board" => "jobs4"})
        |> json_response(200)

      assert done["board"]["code"] == "jobs4"
      assert done["result"]["unchanged"] == 1
      assert Enum.map(done["vault"]["mappings"], & &1["path"]) == ["/", "/Work"]
      assert Wiki.get_page!(page.id).board_id == jobs.id
    end

    test "new_board makes one; a missing board is a 400, a mapping path a 422", %{conn: conn} do
      conn |> post("/api/vaults/Brain/split", %{"path" => "/Work"}) |> json_response(400)

      conn
      |> post("/api/vaults/Brain/split", %{"path" => "/", "new_board" => "Fresh"})
      |> json_response(422)

      done =
        conn
        |> post("/api/vaults/Brain/split", %{"path" => "/Work", "new_board" => "Careers"})
        |> json_response(200)

      assert done["board"]["name"] == "Careers"
    end
  end

  describe "a board kept inside its vault (#757)" do
    test "map with inside, change it, and the board list says so", %{conn: conn} do
      make(conn, "Notes")

      vault =
        conn
        |> post("/api/vaults/Notes/mappings", %{"board" => "kb5", "inside" => true})
        |> json_response(201)
        |> Map.fetch!("vault")

      assert [%{"path" => "/", "inside" => true}] = vault["mappings"]

      boards = conn |> get("/api/boards") |> json_response(200) |> Map.fetch!("boards")
      assert %{"inside_vault" => "Notes"} = Enum.find(boards, &(&1["code"] == "kb5"))
      assert %{"inside_vault" => nil} = Enum.find(boards, &(&1["code"] == "jobs4"))

      out =
        conn
        |> patch("/api/vaults/Notes/mappings", %{"path" => "/", "inside" => false})
        |> json_response(200)

      assert [%{"inside" => false}] = out["vault"]["mappings"]
      [%{"id" => id}] = out["vault"]["mappings"]

      back =
        conn
        |> patch("/api/vaults/Notes/mappings/#{id}", %{"inside" => "true"})
        |> json_response(200)

      assert [%{"inside" => true}] = back["vault"]["mappings"]
    end

    test "refusals: a folder's mapping, nothing said, no such mapping", %{conn: conn} do
      make(conn, "Notes")

      conn
      |> post("/api/vaults/Notes/mappings", %{
        "path" => "/Journal",
        "board" => "jobs4",
        "folder" => "Notes"
      })
      |> json_response(201)

      assert conn
             |> patch("/api/vaults/Notes/mappings", %{"path" => "/Journal", "inside" => true})
             |> json_response(422)
             |> inspect() =~ "only a whole board"

      conn |> patch("/api/vaults/Notes/mappings", %{"path" => "/Journal"}) |> json_response(400)
      conn |> patch("/api/vaults/Notes/mappings", %{"inside" => true}) |> json_response(400)

      conn
      |> patch("/api/vaults/Notes/mappings", %{"path" => "/Nope", "inside" => true})
      |> json_response(404)
    end

    test "with_board makes the vault a board to hold its pages", %{conn: conn} do
      vault =
        conn
        |> post("/api/vaults", %{"name" => "Brain", "with_board" => true})
        |> json_response(201)
        |> Map.fetch!("vault")

      assert [%{"path" => "/", "inside" => true, "board" => %{"name" => "Brain"}}] =
               vault["mappings"]

      conn
      |> post("/api/vaults", %{"name" => "brain", "with_board" => true})
      |> json_response(422)
    end
  end
end
