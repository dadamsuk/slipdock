defmodule Slipdock.ToolsListingTest do
  @moduledoc """
  Who sees a Tool (#964): its owner, the people it is shared with, and —
  once an admin approves a version for listing — everybody, who then sees
  that version and no newer one until it is approved in its turn.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Repo, Tools}

  setup do
    owner = user_fixture("listing-owner@example.com")

    admin =
      "listing-admin@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(admin: true)
      |> Repo.update!()

    friend = user_fixture("listing-friend@example.com")
    stranger = user_fixture("listing-stranger@example.com")
    name = unique_name()
    {:ok, v1} = Tools.publish(owner, package(name, "1.0.0"))
    {:ok, _} = Tools.share(owner, v1.tool, friend)

    %{owner: owner, admin: admin, friend: friend, stranger: stranger, name: name, v1: v1}
  end

  defp tool(name), do: Repo.get_by!(Tools.Tool, slug: name)

  test "before any listing: owner and grantee see it, nobody else", ctx do
    tool = tool(ctx.name)

    assert Tools.access(ctx.owner, tool) == :owner
    assert Tools.access(ctx.friend, tool) == :shared
    assert Tools.access(ctx.stranger, tool) == :none
    assert Tools.access(ctx.admin, tool) == :none

    assert Enum.map(Tools.list_for(ctx.friend), & &1.slug) |> Enum.member?(ctx.name)
    refute Enum.map(Tools.list_for(ctx.stranger), & &1.slug) |> Enum.member?(ctx.name)
  end

  test "asking for a listing shows nothing until an admin approves", ctx do
    {:ok, _} = Tools.request_listing(ctx.owner, ctx.v1)

    assert Tools.access(ctx.stranger, tool(ctx.name)) == :none
    assert [%{id: id}] = Enum.filter(Tools.listing_queue(), &(&1.tool_id == ctx.v1.tool_id))
    assert id == ctx.v1.id

    {:ok, _} = Tools.approve_listing(ctx.admin, Repo.reload(ctx.v1))

    tool = tool(ctx.name)
    assert Tools.access(ctx.stranger, tool) == :listed
    assert Tools.visible_version(ctx.stranger, tool).version == "1.0.0"
    assert Enum.member?(Enum.map(Tools.list_for(ctx.stranger), & &1.slug), ctx.name)
    refute Enum.any?(Tools.listing_queue(), &(&1.id == ctx.v1.id))
  end

  test "an unapproved newer version doesn't replace the listed one", ctx do
    {:ok, _} = Tools.request_listing(ctx.owner, ctx.v1)
    {:ok, _} = Tools.approve_listing(ctx.admin, Repo.reload(ctx.v1))
    {:ok, v2} = Tools.publish(ctx.owner, package(ctx.name, "2.0.0", %{"README.md" => "# Two"}))

    tool = tool(ctx.name)
    # The owner and the grantee see the latest; everybody else the listed one.
    assert Tools.visible_version(ctx.owner, tool).version == "2.0.0"
    assert Tools.visible_version(ctx.friend, tool).version == "2.0.0"
    assert Tools.visible_version(ctx.stranger, tool).version == "1.0.0"
    assert Tools.visible_version(ctx.stranger, tool, "2.0.0") == nil

    Slipdock.TestConfig.own_uploads_dir()
    assert {:ok, %{version: %{version: "1.0.0"}}} = Tools.install_board(ctx.stranger, tool)

    # Asked for and approved, it takes over.
    {:ok, _} = Tools.request_listing(ctx.owner, v2)
    assert Tools.visible_version(ctx.stranger, tool(ctx.name)).version == "1.0.0"
    {:ok, _} = Tools.approve_listing(ctx.admin, Repo.reload(v2))
    assert Tools.visible_version(ctx.stranger, tool(ctx.name)).version == "2.0.0"
  end

  test "approving an old request never takes a newer listing back", ctx do
    {:ok, v2} = Tools.publish(ctx.owner, package(ctx.name, "2.0.0"))
    {:ok, _} = Tools.request_listing(ctx.owner, ctx.v1)
    {:ok, _} = Tools.request_listing(ctx.owner, v2)
    {:ok, _} = Tools.approve_listing(ctx.admin, Repo.reload(v2))
    {:ok, _} = Tools.approve_listing(ctx.admin, Repo.reload(ctx.v1))

    assert Tools.listed_version(tool(ctx.name)).version == "2.0.0"
  end

  test "a declined request stays unlisted and says why", ctx do
    {:ok, _} = Tools.request_listing(ctx.owner, ctx.v1)

    {:ok, v} =
      Tools.decline_listing(ctx.admin, Repo.reload(ctx.v1), "skills write outside the board")

    assert v.declined_reason == "skills write outside the board"
    assert Tools.access(ctx.stranger, tool(ctx.name)) == :none
    refute Enum.any?(Tools.listing_queue(), &(&1.id == v.id))

    # Asking again puts it back in the queue.
    {:ok, _} = Tools.request_listing(ctx.owner, v)
    assert Enum.any?(Tools.listing_queue(), &(&1.id == v.id))
  end

  test "only the owner asks, only an admin decides, and unlisting hides it again", ctx do
    assert {:error, _} = Tools.request_listing(ctx.friend, ctx.v1)
    {:ok, _} = Tools.request_listing(ctx.owner, ctx.v1)
    assert {:error, _} = Tools.approve_listing(ctx.owner, Repo.reload(ctx.v1))
    assert {:error, _} = Tools.decline_listing(ctx.friend, Repo.reload(ctx.v1), "no")

    {:ok, _} = Tools.approve_listing(ctx.admin, Repo.reload(ctx.v1))
    assert {:error, _} = Tools.unlist(ctx.stranger, tool(ctx.name))
    {:ok, _} = Tools.unlist(ctx.owner, tool(ctx.name))

    assert Tools.access(ctx.stranger, tool(ctx.name)) == :none
    assert Tools.access(ctx.friend, tool(ctx.name)) == :shared
  end
end
