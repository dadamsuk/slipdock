defmodule Slipdock.WikiTreeFolderPlacementsTest do
  @moduledoc """
  A folder also filed in another, in the tree (#808, #810): an also-row after
  the folders at home there, keyed by its place so it opens on its own, and
  its whole subtree inside it, only as far as the reader may see.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Wiki.{FolderPlacements, Tree}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Brain", "code" => "tfp"}, owner: user)
    {:ok, home} = Wiki.create_folder(board, %{"name" => "Home"})
    {:ok, topic} = Wiki.create_folder(board, %{"name" => "Topic", "parent_id" => home.id})
    {:ok, inner} = Wiki.create_folder(board, %{"name" => "Inner", "parent_id" => topic.id})
    {:ok, other} = Wiki.create_folder(board, %{"name" => "Other"})
    {:ok, _} = Wiki.create_folder(board, %{"name" => "Zeta", "parent_id" => other.id})

    {:ok, note} =
      Wiki.create_page(board, %{"title" => "Note", "folder_id" => topic.id}, user: user)

    {:ok, _} =
      Wiki.create_page(
        board,
        %{"title" => "Draft", "folder_id" => topic.id, "status" => "draft"},
        user: user
      )

    {:ok, _} = FolderPlacements.add(topic, other, user)

    %{user: user, board: board, home: home, topic: topic, inner: inner, other: other, note: note}
  end

  defp rows(board, ref, opts), do: elem(Tree.children(board, ref, opts), 1)

  test "the placed folder follows the folders at home, marked and keyed by its place", ctx do
    rows = rows(ctx.board, {:folder, ctx.other.id}, as: ctx.user)

    assert [
             %{title: "Zeta"},
             %{title: "Topic", kind: "folder", also: true, placed_in: placed_in, key: key} =
               placed
           ] = rows

    assert placed_in == ctx.other.id
    assert key == "at:#{ctx.other.id}|folder:#{ctx.topic.id}"
    # Inner, Note and Draft are under it, so it opens; its home row is untouched.
    assert placed.count == 3
    home_rows = rows(ctx.board, {:folder, ctx.home.id}, as: ctx.user)
    assert [%{title: "Topic"} = at_home] = home_rows
    refute Map.has_key?(at_home, :also)
    # Other's count includes the folder placed in it.
    assert %{count: 2} = Enum.find(rows(ctx.board, :root, as: ctx.user), &(&1.title == "Other"))
  end

  test "inside it: its own rows, keyed through the place, nested as at home", ctx do
    inside =
      ctx.board
      |> rows({:folder, ctx.topic.id}, as: ctx.user)
      |> Tree.through_placement([ctx.other.id])

    assert Enum.map(inside, &{&1.title, &1.key, &1.via}) == [
             {"Inner", "at:#{ctx.other.id}|folder:#{ctx.inner.id}", true},
             {"Draft", "at:#{ctx.other.id}|page:#{Enum.at(inside, 1).id}", true},
             {"Note", "at:#{ctx.other.id}|page:#{ctx.note.id}", true}
           ]
  end

  test "readability holds inside a placed folder: drafts only for writers", ctx do
    inside = rows(ctx.board, {:folder, ctx.topic.id}, as: ctx.user, status: "published")
    assert Enum.map(inside, & &1.title) == ["Inner", "Note"]
  end

  test "a placed folder on a board the reader can't open is not shown", ctx do
    jobs = board_fixture(%{"name" => "Journal", "code" => "tfpjobs"}, owner: ctx.user)
    {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "V"})
    {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.board})
    {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/Journal", board: jobs})
    {:ok, away} = Wiki.create_folder(jobs, %{"name" => "Away"})
    {:ok, _} = FolderPlacements.add(away, ctx.other, ctx.user)

    # In the order they were filed there.
    assert ["Zeta", "Topic", "Away"] =
             Enum.map(rows(ctx.board, {:folder, ctx.other.id}, as: ctx.user), & &1.title)

    reader = user_fixture("reader@example.com")
    share_fixture(ctx.board, reader, "read")

    assert ["Zeta", "Topic"] =
             Enum.map(rows(ctx.board, {:folder, ctx.other.id}, as: reader), & &1.title)
  end

  test "keys through placements read back, and junk does not" do
    assert Tree.via_key([5], "folder:9") == "at:5|folder:9"
    assert Tree.via_key([5], "at:12|page:3") == "at:5.12|page:3"
    assert Tree.split_via("at:5.12|page:3") == {:ok, [5, 12], "page:3"}
    assert Tree.split_via("folder:3") == :none

    for bad <- [
          "at:|folder:3",
          "at:x|folder:3",
          "at:5|root",
          "at:5|nope:1",
          "at:5",
          "at:0|page:1"
        ],
        do: assert(Tree.split_via(bad) == :error, bad)

    deep = Enum.map_join(1..17, ".", &to_string/1)
    assert Tree.split_via("at:#{deep}|folder:1") == :error
  end
end
