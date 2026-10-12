defmodule SlipdockWeb.API.VaultsTest do
  @moduledoc "`/api/vaults`: making, mapping, locating and deleting a vault over HTTP."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Vaults, Wiki}

  setup %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kb"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobs"}, owner: user)
    {:ok, _} = Wiki.create_folder(jobs, %{"name" => "Notes"})
    %{conn: put_req_header(conn, "accept", "application/json"), kb: kb, jobs: jobs}
  end

  defp make(conn, name),
    do:
      conn |> post("/api/vaults", %{"name" => name}) |> json_response(201) |> Map.fetch!("vault")

  test "the whole road: make, map, show, locate, unmap, rename, delete", %{conn: conn} do
    assert make(conn, "Notes")["mappings"] == []

    conn |> post("/api/vaults/Notes/mappings", %{"board" => "kb"}) |> json_response(201)

    vault =
      conn
      |> post("/api/vaults/notes/mappings", %{
        "path" => "/Jobs",
        "board" => "jobs",
        "folder" => "Notes"
      })
      |> json_response(201)
      |> Map.fetch!("vault")

    assert [%{"path" => "/", "folder" => nil}, %{"path" => "/Jobs"} = jobs] = vault["mappings"]
    assert jobs["board"]["code"] == "jobs"
    assert jobs["folder"]["path"] == "Notes"

    assert [%{"name" => "Notes"}] =
             conn |> get("/api/vaults") |> json_response(200) |> Map.fetch!("vaults")

    assert %{"vault" => %{"id" => id}} = conn |> get("/api/vaults/Notes") |> json_response(200)

    located =
      conn |> get("/api/vaults/#{id}/locate?path=/Jobs/Acme/Call.md") |> json_response(200)

    assert located["mapping"]["path"] == "/Jobs"
    assert located["rest"] == "Acme/Call.md"

    after_unmap =
      conn
      |> delete("/api/vaults/Notes/mappings?path=/Jobs")
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
           |> post("/api/vaults/Notes/mappings", %{"board" => "jobs", "folder" => "Missing"})
           |> json_response(404)

    assert conn |> get("/api/vaults/Notes/locate?path=/x.md") |> json_response(404)

    assert %{"error" => error} =
             conn |> delete("/api/vaults/Notes/mappings") |> json_response(400)

    assert error =~ "mapping"

    # A board you can only read cannot go into your vault.
    owner = user_fixture("someone@example.com")
    theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs"}, owner: owner)
    share_fixture(theirs, user, "read")

    assert %{"error" => forbidden} =
             conn
             |> post("/api/vaults/Notes/mappings", %{"board" => "theirs"})
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
    conn |> post("/api/vaults/Notes/mappings", %{"board" => "kb"}) |> json_response(201)

    conn
    |> post("/api/vaults/Notes/mappings", %{"path" => "/Jobs", "board" => "jobs"})
    |> json_response(201)

    {:ok, note} = Wiki.create_page(jobs, %{"title" => "Acme"}, user: user)

    {:ok, _} =
      Wiki.create_page(kb, %{"title" => "Linker", "body" => "[[Acme]] [[Ghost]]"}, user: user)

    found = conn |> get("/api/vaults/Notes/resolve?link=Jobs/Acme") |> json_response(200)
    assert found["page"]["code"] == note.code
    assert found["path"] == "/Jobs/Acme"

    assert conn |> get("/api/vaults/Notes/resolve?link=Nope") |> json_response(404)
    assert conn |> get("/api/vaults/Notes/resolve") |> json_response(400)

    assert [%{"title" => "Ghost", "from" => [%{"title" => "Linker"}]}] =
             conn |> get("/api/vaults/Notes/wanted") |> json_response(200) |> Map.fetch!("wanted")
  end
end
