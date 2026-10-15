defmodule SlipdockWeb.API.VaultSyncStubsTest do
  @moduledoc "The sync listing's stubs (#819) go only to a client that asks for them."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Vaults, Wiki}

  setup %{user: sharee} do
    owner = user_fixture("owner@example.com")
    theirs = board_fixture(%{"name" => "Owner's"}, owner: owner)
    plan = page_fixture(theirs, %{"title" => "Plan", "body" => "SECRET"}, user: owner)
    mine = board_fixture(%{"name" => "Mine"}, owner: sharee)
    {:ok, inbox} = Wiki.create_folder(mine, %{"name" => "Inbox"})
    {:ok, vault} = Vaults.create_vault(sharee, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, sharee, %{path: "/", board: mine})
    {:ok, _} = Access.grant(plan, sharee, "read", owner)
    {:ok, _} = Wiki.Placements.add(plan, inbox, sharee)
    %{vault: vault, plan: plan}
  end

  test "?stubs=1 lists the stub, with the server's own address in its link", c do
    body =
      c.conn
      |> put_req_header("accept", "application/json")
      |> get("/api/vaults/#{c.vault.id}/sync?stubs=1")
      |> json_response(200)

    assert [%{"kind" => "stub", "path" => "Inbox/Plan.md", "content" => content}] =
             Enum.filter(body["entries"], &(&1["kind"] == "stub"))

    assert content =~ ~r{^\[Plan\]\(https?://[^)]+/shared/pages/#{c.plan.id}\)\n$}
    refute content =~ "SECRET"
  end

  test "without it, no stubs: a client from before them would take them for pages", c do
    body =
      c.conn
      |> put_req_header("accept", "application/json")
      |> get("/api/vaults/#{c.vault.id}/sync")
      |> json_response(200)

    refute Enum.any?(body["entries"], &(&1["kind"] == "stub"))
  end
end
