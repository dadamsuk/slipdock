defmodule SlipdockWeb.API.SkillRegistryTest do
  @moduledoc """
  The skills registry over REST (#2072): sources added, read, refreshed and
  removed with the page's permissions and its refusal sentences; an entry in
  full; a board's skills enabled, re-pinned and disabled by a writer only,
  pinned to the hash given; the Playbook stages naming a skill; and a
  read-only token that reads but changes nothing.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Handbook, SkillRegistry, SkillRegistryStub, TestConfig, Wiki}

  @repo "https://github.com/octo/skills"

  defp skill(name, body \\ "Ask one question at a time.") do
    "---\nname: #{name}\ndescription: Asks.\n---\n\n#{body}\n"
  end

  defp serve(body),
    do:
      SkillRegistryStub.put("octo/skills", %{
        files: %{"grilling/SKILL.md" => skill("grilling", body)},
        licence: "MIT"
      })

  setup %{conn: conn, user: user} do
    SkillRegistryStub.start(%{})
    serve("Ask one question at a time.")
    board = board_fixture(%{"name" => "Plans"}, owner: user)
    %{conn: put_req_header(conn, "accept", "application/json"), board: board}
  end

  defp token_conn(user, scope \\ "write") do
    {token, _} = Accounts.create_api_token(user, "registry", scope: scope)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp add!(conn) do
    conn
    |> post(~p"/api/skill-sources", %{url: @repo})
    |> json_response(201)
    |> Map.fetch!("source")
  end

  describe "sources" do
    test "add, list, read, refresh and remove one", %{conn: conn} do
      source = add!(conn)
      assert source["name"] == "octo/skills"
      assert source["licence"] == "MIT"
      assert source["seed"] == false
      assert source["can_manage"] == true

      assert [%{"name" => "grilling", "content_hash" => hash, "path" => "grilling/SKILL.md"}] =
               source["entries"]

      assert is_binary(hash)
      refute Map.has_key?(hd(source["entries"]), "body")

      assert %{"sources" => [%{"id" => id}]} =
               conn |> get(~p"/api/skill-sources") |> json_response(200)

      assert id == source["id"]

      assert %{"source" => %{"id" => ^id}} =
               conn |> get(~p"/api/skill-sources/#{id}") |> json_response(200)

      serve("Ask them all at once.")

      assert %{"changes" => %{"changed" => ["grilling"], "added" => [], "removed" => []}} =
               conn |> post(~p"/api/skill-sources/#{id}/refresh") |> json_response(200)

      assert %{"deleted" => %{"name" => "octo/skills"}} =
               conn |> delete(~p"/api/skill-sources/#{id}") |> json_response(200)

      assert %{"sources" => []} = conn |> get(~p"/api/skill-sources") |> json_response(200)
    end

    test "a refused fetch is a 422 with its sentence", %{conn: conn} do
      assert %{"error" => "https://intranet.test/SKILL.md is not a public address."} =
               conn
               |> post(~p"/api/skill-sources", %{url: "https://intranet.test/SKILL.md"})
               |> json_response(422)

      SkillRegistryStub.put("/big/SKILL.md", skill("big", String.duplicate("a", 5000)))
      TestConfig.merge(:skill_registry, max_file_bytes: 1000)

      assert %{"error" => "https://skills.example.com/big/SKILL.md is larger than 1 KB."} =
               conn
               |> post(~p"/api/skill-sources", %{url: "https://skills.example.com/big/SKILL.md"})
               |> json_response(422)

      assert %{"error" => "A source needs a URL."} =
               conn |> post(~p"/api/skill-sources", %{}) |> json_response(422)
    end

    test "another user's source is a 404 everywhere; a seed is read-only to a non-admin", %{
      conn: conn
    } do
      other = user_fixture("registry-api-other@example.com")
      {:ok, theirs} = SkillRegistry.add_source(other, @repo)
      [entry] = theirs.entries

      assert conn |> get(~p"/api/skill-sources/#{theirs.id}") |> json_response(404)
      assert conn |> post(~p"/api/skill-sources/#{theirs.id}/refresh") |> json_response(404)
      assert conn |> delete(~p"/api/skill-sources/#{theirs.id}") |> json_response(404)
      assert conn |> get(~p"/api/skill-entries/#{entry.id}") |> json_response(404)
      assert conn |> get(~p"/api/skill-sources/nope") |> json_response(404)

      SkillRegistryStub.put("octo/seed", %{files: %{"s/SKILL.md" => skill("seeded")}})
      {:ok, seed} = SkillRegistry.add_source(nil, "https://github.com/octo/seed")

      assert %{"source" => %{"seed" => true, "can_manage" => false}} =
               conn |> get(~p"/api/skill-sources/#{seed.id}") |> json_response(200)

      assert %{"error" => "forbidden: Only whoever added octo/seed can change it."} =
               conn |> delete(~p"/api/skill-sources/#{seed.id}") |> json_response(403)
    end
  end

  describe "a seed (#2075)" do
    test "an admin adds one with seed: true; anyone else is refused", %{conn: conn, user: user} do
      assert %{"error" => "forbidden: Only an admin can add a source for everyone."} =
               conn
               |> post(~p"/api/skill-sources", %{url: @repo, seed: true})
               |> json_response(403)

      assert SkillRegistry.list_sources(user) == []

      admin = user_fixture("registry-api-admin@example.com")
      {:ok, admin} = admin |> Ecto.Changeset.change(admin: true) |> Slipdock.Repo.update()

      assert %{"source" => %{"seed" => true, "can_manage" => true}} =
               admin
               |> token_conn()
               |> post(~p"/api/skill-sources", %{url: @repo, seed: true})
               |> json_response(201)

      assert %{"sources" => [%{"seed" => true, "can_manage" => false}]} =
               conn |> get(~p"/api/skill-sources") |> json_response(200)
    end
  end

  describe "an entry" do
    test "is the whole file, where it is enabled and the diff when changed", %{
      conn: conn,
      board: board
    } do
      %{"id" => source_id, "entries" => [%{"id" => id, "content_hash" => hash}]} = add!(conn)

      assert %{"entry" => entry} = conn |> get(~p"/api/skill-entries/#{id}") |> json_response(200)
      assert entry["body"] =~ "Ask one question at a time."
      assert entry["source"]["name"] == "octo/skills"
      assert entry["enabled_on"] == []

      conn
      |> post(~p"/api/boards/#{board.id}/skills", %{entry: id, hash: hash})
      |> json_response(201)

      serve("Ask them all at once.")
      conn |> post(~p"/api/skill-sources/#{source_id}/refresh") |> json_response(200)

      assert %{"entry" => %{"enabled_on" => [pin]}} =
               conn |> get(~p"/api/skill-entries/#{id}") |> json_response(200)

      assert pin["board"]["name"] == "Plans"
      assert pin["status"] == "changed"
      assert pin["can_change"] == true
      assert pin["pinned_hash"] == hash
      assert pin["upstream_hash"] != hash
      assert %{"op" => "del", "lines" => ["Ask one question at a time."]} in pin["diff"]
      assert %{"op" => "ins", "lines" => ["Ask them all at once."]} in pin["diff"]
    end
  end

  describe "a board's skills" do
    test "enable pinned to the hash read, re-pin after a change, disable", %{
      conn: conn,
      board: board
    } do
      %{"id" => source_id, "entries" => [%{"id" => id, "content_hash" => hash}]} = add!(conn)

      assert %{"skill" => skill} =
               conn
               |> post(~p"/api/boards/#{board.id}/skills", %{entry: id, hash: hash})
               |> json_response(201)

      assert skill["name"] == "grilling"
      assert skill["pinned_hash"] == hash
      assert skill["status"] == "current"
      assert skill["text"] =~ "Ask one question at a time."

      serve("Ask them all at once.")
      conn |> post(~p"/api/skill-sources/#{source_id}/refresh") |> json_response(200)
      new_hash = SkillRegistry.get_enabled(board, "grilling").entry.content_hash

      # The hash it had is not the text there now.
      assert %{"error" => "grilling has changed since you read it." <> _} =
               conn
               |> patch(~p"/api/boards/#{board.id}/skills/grilling", %{hash: hash})
               |> json_response(422)

      assert %{"skill" => %{"pinned_hash" => ^new_hash, "text" => text}} =
               conn
               |> patch(~p"/api/boards/#{board.id}/skills/grilling", %{hash: new_hash})
               |> json_response(200)

      assert text =~ "all at once"

      assert %{"disabled" => %{"name" => "grilling"}} =
               conn |> delete(~p"/api/boards/#{board.id}/skills/grilling") |> json_response(200)

      assert SkillRegistry.enabled(board) == []

      assert conn |> delete(~p"/api/boards/#{board.id}/skills/grilling") |> json_response(404)
    end

    test "a stale hash, a missing one, an unseen entry and a second of a name are refused", %{
      conn: conn,
      board: board
    } do
      %{"entries" => [%{"id" => id, "content_hash" => hash}]} = add!(conn)
      path = ~p"/api/boards/#{board.id}/skills"

      assert %{"error" => "grilling has changed since you read it." <> _} =
               conn |> post(path, %{entry: id, hash: "stale"}) |> json_response(422)

      assert %{"error" => "hash is required"} =
               conn |> post(path, %{entry: id}) |> json_response(400)

      assert %{"error" => "entry is required" <> _} =
               conn |> post(path, %{hash: hash}) |> json_response(400)

      other = user_fixture("registry-api-unseen@example.com")
      SkillRegistryStub.put("octo/theirs", %{files: %{"t/SKILL.md" => skill("theirs")}})

      {:ok, %{entries: [theirs]}} =
        SkillRegistry.add_source(other, "https://github.com/octo/theirs")

      assert conn
             |> post(path, %{entry: theirs.id, hash: theirs.content_hash})
             |> json_response(404)

      conn |> post(path, %{entry: id, hash: hash}) |> json_response(201)

      assert %{"error" => "grilling is already enabled on Plans."} =
               conn |> post(path, %{entry: id, hash: hash}) |> json_response(422)
    end

    test "a reader is refused; a board they can't see is a 404", %{user: user, board: board} do
      {:ok, %{entries: [entry]}} = SkillRegistry.add_source(nil, @repo)
      reader = user_fixture("registry-api-reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", user)

      reader_conn = token_conn(reader)

      assert reader_conn
             |> post(~p"/api/boards/#{board.id}/skills", %{
               entry: entry.id,
               hash: entry.content_hash
             })
             |> json_response(403)

      {:ok, _} = SkillRegistry.enable(user, board, entry.id, entry.content_hash)

      assert reader_conn
             |> delete(~p"/api/boards/#{board.id}/skills/grilling")
             |> json_response(403)

      outsider_conn = token_conn(user_fixture("registry-api-outsider@example.com"))

      assert outsider_conn
             |> delete(~p"/api/boards/#{board.id}/skills/grilling")
             |> json_response(404)

      assert [_] = SkillRegistry.enabled(board)
    end

    test "a read-only token reads but changes nothing", %{user: user, board: board} do
      {:ok, %{entries: [entry]}} = SkillRegistry.add_source(user, @repo)
      ro = token_conn(user, "read")

      assert %{"sources" => [_]} = ro |> get(~p"/api/skill-sources") |> json_response(200)
      assert ro |> get(~p"/api/skill-entries/#{entry.id}") |> json_response(200)

      assert %{"error" => "this API token is read-only" <> _} =
               ro
               |> post(~p"/api/boards/#{board.id}/skills", %{
                 entry: entry.id,
                 hash: entry.content_hash
               })
               |> json_response(403)

      assert ro |> post(~p"/api/skill-sources", %{url: @repo}) |> json_response(403)
      assert SkillRegistry.enabled(board) == []

      # A write token is enough.
      assert user
             |> token_conn()
             |> post(~p"/api/boards/#{board.id}/skills", %{
               entry: entry.id,
               hash: entry.content_hash
             })
             |> json_response(201)
    end
  end

  test "the stages naming a skill, flagged when nothing provides it", %{
    conn: conn,
    user: user,
    board: board
  } do
    assert %{"boards" => []} = conn |> get(~p"/api/skill-stages") |> json_response(200)

    {:ok, _} = Handbook.install(user, board)
    playbook = Enum.find(Handbook.find(board).pages, &(Handbook.key(&1) == "playbook"))
    body = String.replace(playbook.body, "## Decide\n", "- skill: grilling\n\n## Decide\n")
    {:ok, _} = Wiki.update_page(playbook, %{"body" => body}, user: user)

    assert %{"boards" => [%{"board" => %{"name" => "Plans"}, "stages" => [stage]}]} =
             conn |> get(~p"/api/skill-stages") |> json_response(200)

    assert %{"stage" => "Grill", "skill" => "grilling", "enabled" => nil, "flagged" => true} =
             stage

    %{"entries" => [%{"id" => id, "content_hash" => hash}]} = add!(conn)

    conn
    |> post(~p"/api/boards/#{board.id}/skills", %{entry: id, hash: hash})
    |> json_response(201)

    assert %{"boards" => [%{"stages" => [stage]}]} =
             conn |> get(~p"/api/skill-stages") |> json_response(200)

    assert %{
             "enabled" => %{"source_name" => "octo/skills", "status" => "current"},
             "flagged" => false
           } =
             stage
  end
end
