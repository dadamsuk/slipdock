defmodule SlipdockWeb.MCP.SkillRegistryToolTest do
  @moduledoc """
  `skill_registry` (#2072): the skills registry over MCP, each action through
  `tools/call` as a client makes it, and the refusals: a fetch's sentence,
  another user's source, a stale hash, a reader, a board the caller can't
  see, and a read-only token.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, SkillRegistry, SkillRegistryStub}

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

  setup %{user: user} do
    SkillRegistryStub.start(%{})
    serve("Ask one question at a time.")
    %{board: board_fixture(%{"name" => "Plans"}, owner: user)}
  end

  defp call(conn, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "skill_registry", arguments: args}
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
    assert result["isError"] == true, inspect(result)
    [%{"text" => text}] = result["content"]
    text
  end

  defp token_conn(user, scope \\ "write") do
    {token, _} = Accounts.create_api_token(user, "mcp", scope: scope)
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  test "add, list, read a source and an entry, refresh and remove", %{conn: conn} do
    source = ok!(call(conn, %{action: "add", url: @repo}))["source"]
    assert source["name"] == "octo/skills"
    [%{"id" => entry_id, "content_hash" => hash}] = source["entries"]

    assert [%{"id" => id}] = ok!(call(conn, %{action: "sources"}))["sources"]
    assert id == source["id"]
    assert ok!(call(conn, %{action: "source", source: id}))["source"]["id"] == id

    entry = ok!(call(conn, %{action: "entry", entry: entry_id}))["entry"]
    assert entry["body"] =~ "Ask one question at a time."
    assert entry["content_hash"] == hash

    serve("Ask them all at once.")
    refreshed = ok!(call(conn, %{action: "refresh", source: id}))
    assert refreshed["changes"]["changed"] == ["grilling"]

    assert ok!(call(conn, %{action: "remove", source: id}))["deleted"]["name"] == "octo/skills"
    assert ok!(call(conn, %{action: "sources"}))["sources"] == []
  end

  test "a refused fetch, an unknown or another user's source, and bad arguments", %{conn: conn} do
    assert error!(call(conn, %{action: "add", url: "https://intranet.test/SKILL.md"})) ==
             "https://intranet.test/SKILL.md is not a public address."

    assert error!(call(conn, %{action: "add"})) == "url is required"

    {:ok, theirs} =
      SkillRegistry.add_source(user_fixture("mcp-registry-other@example.com"), @repo)

    [their_entry] = theirs.entries

    assert error!(call(conn, %{action: "source", source: theirs.id})) =~
             "no skill source you can see"

    assert error!(call(conn, %{action: "remove", source: theirs.id})) =~
             "no skill source you can see"

    assert error!(call(conn, %{action: "entry", entry: their_entry.id})) =~ "no skill you can see"
    assert error!(call(conn, %{action: "source", source: "x"})) == "source must be an id"
    assert error!(call(conn, %{action: "teleport"})) =~ "action must be one of"
  end

  test "add with seed: an admin's is everyone's; anyone else is refused", %{
    conn: conn,
    user: user
  } do
    assert conn |> call(%{action: "add", url: @repo, seed: true}) |> error!() =~
             "Only an admin can add a source for everyone."

    assert SkillRegistry.list_sources(user) == []

    admin = user_fixture("registry-mcp-admin@example.com")
    {:ok, admin} = admin |> Ecto.Changeset.change(admin: true) |> Slipdock.Repo.update()

    assert %{"source" => %{"seed" => true}} =
             admin |> token_conn() |> call(%{action: "add", url: @repo, seed: true}) |> ok!()

    assert [%{owner_id: nil}] = SkillRegistry.list_sources(user)
  end

  test "enable pinned to the hash read, re-pin after a change, disable", %{
    conn: conn,
    board: board
  } do
    %{"id" => source_id, "entries" => [%{"id" => entry_id, "content_hash" => hash}]} =
      ok!(call(conn, %{action: "add", url: @repo}))["source"]

    assert error!(
             call(conn, %{action: "enable", board: "#{board.id}", entry: entry_id, hash: "stale"})
           ) =~
             "has changed since you read it"

    pinned =
      ok!(call(conn, %{action: "enable", board: "#{board.id}", entry: entry_id, hash: hash}))[
        "skill"
      ]

    assert pinned["pinned_hash"] == hash
    assert pinned["text"] =~ "one question"

    serve("Ask them all at once.")
    ok!(call(conn, %{action: "refresh", source: source_id}))

    entry = ok!(call(conn, %{action: "entry", entry: entry_id}))["entry"]
    [%{"status" => "changed", "diff" => diff, "upstream_hash" => new_hash}] = entry["enabled_on"]
    assert %{"op" => "ins", "lines" => ["Ask them all at once."]} in diff

    repinned =
      ok!(call(conn, %{action: "repin", board: "#{board.id}", name: "grilling", hash: new_hash}))[
        "skill"
      ]

    assert repinned["pinned_hash"] == new_hash
    assert repinned["status"] == "current"

    assert ok!(call(conn, %{action: "disable", board: "#{board.id}", name: "grilling"}))[
             "disabled"
           ][
             "name"
           ] == "grilling"

    assert error!(call(conn, %{action: "disable", board: "#{board.id}", name: "grilling"})) =~
             "no skill named grilling is enabled on Plans"
  end

  test "a reader is refused, and a board the caller can't see is not found", %{
    user: user,
    board: board
  } do
    {:ok, %{entries: [entry]}} = SkillRegistry.add_source(nil, @repo)
    reader = user_fixture("mcp-registry-reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)

    args = %{action: "enable", board: "#{board.id}", entry: entry.id, hash: entry.content_hash}
    assert error!(call(token_conn(reader), args)) =~ "you don't edit this board"

    outsider = token_conn(user_fixture("mcp-registry-outsider@example.com"))
    assert error!(call(outsider, args)) =~ "no board you can see"
    assert SkillRegistry.enabled(board) == []
  end

  test "stages lists the Playbook stages naming a skill", %{conn: conn} do
    assert ok!(call(conn, %{action: "stages"}))["boards"] == []
  end

  test "a read-only token reads but changes nothing", %{user: user, board: board} do
    {:ok, %{entries: [entry]}} = SkillRegistry.add_source(user, @repo)
    ro = token_conn(user, "read")

    assert [_] = ok!(call(ro, %{action: "sources"}))["sources"]
    assert ok!(call(ro, %{action: "entry", entry: entry.id}))["entry"]["name"] == "grilling"

    assert error!(call(ro, %{action: "add", url: @repo})) =~ "read-only"

    assert error!(
             call(ro, %{
               action: "enable",
               board: "#{board.id}",
               entry: entry.id,
               hash: entry.content_hash
             })
           ) =~ "read-only"

    assert SkillRegistry.enabled(board) == []
  end
end
