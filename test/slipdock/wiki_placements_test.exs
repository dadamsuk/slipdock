defmodule Slipdock.WikiPlacementsTest do
  @moduledoc """
  One page in several folders (W-103 R12.1, R12.3, R12.4, R12.7): a home
  folder and placements beside it, on the page's board or across its vault,
  each page listed once, and nothing about a placement ever archiving or
  deleting writing.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Vaults, Wiki}
  alias Slipdock.Wiki.Placements

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Brain", "code" => "place"}, owner: user)
    {:ok, home} = Wiki.create_folder(board, %{"name" => "Home"})
    {:ok, other} = Wiki.create_folder(board, %{"name" => "Other"})

    {:ok, page} =
      Wiki.create_page(board, %{"title" => "Note", "body" => "words", "folder_id" => home.id},
        user: user
      )

    %{user: user, board: board, home: home, other: other, page: page}
  end

  defp titles(pages), do: pages |> Enum.map(&{&1.title, &1.also}) |> Enum.sort()

  test "a page is also filed in another folder, and listed there marked also", ctx do
    assert {:ok, [folder]} = Placements.add(ctx.page, ctx.other, ctx.user)
    assert folder.id == ctx.other.id

    assert titles(Wiki.list_pages(ctx.board, folder: ctx.other, as: ctx.user)) == [{"Note", true}]
    assert titles(Wiki.list_pages(ctx.board, folder: ctx.home, as: ctx.user)) == [{"Note", false}]
    # Filing it twice is filing it once; the board's listing has it once.
    assert {:ok, [_]} = Placements.add(ctx.page, ctx.other, ctx.user)
    assert length(Wiki.list_pages(ctx.board)) == 1
  end

  test "the home folder is not a placement; filing a page home drops the placement", ctx do
    assert {:error, :unprocessable_entity, _} = Placements.add(ctx.page, ctx.home, ctx.user)

    {:ok, _} = Placements.add(ctx.page, ctx.other, ctx.user)
    {:ok, page} = Wiki.update_page(ctx.page, %{"folder_id" => ctx.other.id}, user: ctx.user)
    assert Placements.folders(page) == []

    assert titles(Wiki.list_pages(ctx.board, folder: ctx.other, as: ctx.user)) == [
             {"Note", false}
           ]

    {:ok, _} = Placements.add(page, ctx.home, ctx.user)
    {:ok, page} = Wiki.file_page(page, ctx.home)
    assert Placements.folders(page) == []
  end

  test "archiving keeps placements; removing one never archives the page", ctx do
    {:ok, _} = Placements.add(ctx.page, ctx.other, ctx.user)
    {:ok, archived} = Wiki.archive_page(ctx.page)
    assert [_] = Placements.folders(archived)
    assert Wiki.list_pages(ctx.board, folder: ctx.other, as: ctx.user) == []
    assert [_] = Wiki.list_pages(ctx.board, folder: ctx.other, as: ctx.user, archived: :all)

    {:ok, page} = Wiki.unarchive_page(archived)
    assert {:ok, []} = Placements.remove(page, ctx.other, ctx.user)
    assert is_nil(Wiki.get_page!(page.id).archived_at)
    assert {:error, :not_found, _} = Placements.remove(page, ctx.other, ctx.user)
  end

  test "deleting a folder, or the page, takes the placements with it", ctx do
    {:ok, _} = Placements.add(ctx.page, ctx.other, ctx.user)
    {:ok, _} = Wiki.delete_folder(ctx.other)
    assert Placements.folders(ctx.page) == []
    assert Wiki.get_page!(ctx.page.id)

    {:ok, third} = Wiki.create_folder(ctx.board, %{"name" => "Third"})
    {:ok, _} = Placements.add(ctx.page, third, ctx.user)
    {:ok, _} = Wiki.delete_page(ctx.page)
    assert Placements.pages_in(third) == []
  end

  test "a listing's filters reach the placed pages", ctx do
    {:ok, _} = Placements.add(ctx.page, ctx.other, ctx.user)
    assert [_] = Wiki.list_pages(ctx.board, folder: ctx.other, as: ctx.user, q: "words")
    assert [] = Wiki.list_pages(ctx.board, folder: ctx.other, as: ctx.user, q: "nothing like it")
    assert [] = Wiki.list_pages(ctx.board, folder: ctx.other, as: ctx.user, template: true)
  end

  describe "across boards" do
    setup ctx do
      jobs = board_fixture(%{"name" => "Journal", "code" => "placejobs"}, owner: ctx.user)
      {:ok, there} = Wiki.create_folder(jobs, %{"name" => "Notes"})
      %{jobs: jobs, there: there}
    end

    test "only within the vault the page's board is in", ctx do
      assert {:error, :unprocessable_entity, msg} = Placements.add(ctx.page, ctx.there, ctx.user)
      assert msg =~ "same vault"

      {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "V"})
      {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.board})
      {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/Journal", board: ctx.jobs})

      assert {:ok, [_]} = Placements.add(ctx.page, ctx.there, ctx.user)
      assert [%{id: id, also: true}] = Wiki.list_pages(ctx.jobs, folder: ctx.there, as: ctx.user)
      assert id == ctx.page.id
    end

    test "needs write on both boards; a reader of only the folder's board does not see it", ctx do
      {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "V"})
      {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.board})
      {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/Journal", board: ctx.jobs})

      helper = user_fixture("helper@example.com")
      share_fixture(ctx.jobs, helper, "write")
      assert {:error, :forbidden, _} = Placements.add(ctx.page, ctx.there, helper)

      {:ok, _} = Placements.add(ctx.page, ctx.there, ctx.user)
      assert Placements.pages_in(ctx.there, helper) == []
      # With nobody named, another board's page is not handed out.
      assert Placements.pages_in(ctx.there) == []
      assert [_] = Placements.pages_in(ctx.there, ctx.user)
    end

    test "a vault path names a folder on whichever board it is mapped to", ctx do
      assert {:error, :unprocessable_entity, _} = Placements.folder_at(ctx.page, "/Journal/Notes")

      {:ok, vault} = Vaults.create_vault(ctx.user, %{"name" => "V"})
      {:ok, _} = Vaults.add_mapping(vault, ctx.user, %{path: "/", board: ctx.board})

      {:ok, _} =
        Vaults.add_mapping(vault, ctx.user, %{
          path: "/Journal",
          board: ctx.jobs,
          folder: ctx.there
        })

      assert {:ok, %{id: id}} = Placements.folder_at(ctx.page, "/Journal")
      assert id == ctx.there.id
      assert {:error, :not_found, _} = Placements.folder_at(ctx.page, "/Journal/Acme")
      assert {:ok, acme} = Placements.folder_at(ctx.page, "/Journal/Acme", create: true)
      assert acme.board_id == ctx.jobs.id
      assert Wiki.folder_path(acme) == "Notes/Acme"
      assert {:error, :unprocessable_entity, _} = Placements.folder_at(ctx.page, "/")
    end
  end

  test "the board's folders carry their placed pages", ctx do
    {:ok, _} = Placements.add(ctx.page, ctx.other, ctx.user)
    assert %{} = by = Placements.pages_by_folder(ctx.board.id, ctx.user)
    assert [%{id: id, also: true}] = by[ctx.other.id]
    assert id == ctx.page.id
    refute Map.has_key?(by, ctx.home.id)
  end
end
