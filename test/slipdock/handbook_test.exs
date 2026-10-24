defmodule Slipdock.HandbookTest do
  @moduledoc """
  The built-in Handbook Tool (#1262, W-1934): installing it gives a board's
  root a `Handbook/` folder of skeleton pages with front matter and an Index
  that lists the folder by itself.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Handbook, Repo, Wiki}
  alias Slipdock.Wiki.{Folders, Page}
  alias SlipdockWeb.Wiki.Renderer

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Project"}, owner: user)
    %{user: user, board: board}
  end

  defp handbook_pages(board) do
    {:ok, folder} = Folders.find(board, "/Handbook")
    Repo.all(from(p in Page, where: p.folder_id == ^folder.id, order_by: p.id))
  end

  describe "install/3" do
    test "builds the folders and the pages, each with its front matter", %{
      user: user,
      board: board
    } do
      assert Handbook.find(board) == nil
      assert {:ok, result} = Handbook.install(user, board)
      assert result.created
      assert result.board.id == board.id

      assert {:ok, _} = Folders.find(board, "/Handbook")
      assert {:ok, _} = Folders.find(board, "/Handbook/Decisions")

      pages = handbook_pages(board)

      assert Enum.map(pages, & &1.title) == [
               "Index",
               "Specification",
               "Architecture",
               "UX & UI",
               "Components",
               "Data model",
               "Shared modules",
               "Testing & tooling",
               "Operations"
             ]

      ux = Enum.find(pages, &(&1.title == "UX & UI"))
      assert Handbook.key(ux) == "ux"
      assert Handbook.field(ux, "read_when") =~ "screen"
      assert Handbook.field(ux, "covers") == []
      assert ux.summary =~ "interface"
      assert ux.front_matter =~ ~r/\A---\n/

      found = Handbook.find(board)
      assert found.index.title == "Index"
      assert hd(found.pages).title == "Index"
      assert length(found.pages) == 9
    end

    test "installing again duplicates nothing and leaves edited pages alone",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      arch = Enum.find(handbook_pages(board), &(&1.title == "Architecture"))
      {:ok, _} = Wiki.update_page(arch, %{"body" => "# Architecture\n\nOurs now."})

      assert {:ok, again} = Handbook.install(user, board)
      refute again.created
      assert again.report.added["pages"] == []
      assert length(handbook_pages(board)) == 9
      assert Repo.get!(Page, arch.id).body =~ "Ours now."
    end

    test "a sub-board's install goes on the root board, and a subcard finds it",
         %{user: user, board: board} do
      [col | _] = board.columns
      epic = card_fixture(col, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)

      assert {:ok, result} = Handbook.install(user, sub)
      assert result.board.id == board.id
      assert Handbook.find(sub).board.id == board.id
    end

    test "refuses somebody who can't write to the board", %{board: board} do
      stranger = user_fixture("handbook-stranger@example.com")
      assert {:error, message} = Handbook.install(stranger, board)
      assert message =~ "write access"
      assert Handbook.find(board) == nil
    end
  end

  describe "the Index" do
    test "lists the folder's pages, including one added later", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      %{index: index, folder: folder} = Handbook.find(board)

      md = Renderer.to_markdown(index.body, board: board, as: user, page: index)
      assert md =~ "| Title | Summary | Read when |"

      assert md =~
               "Architecture (#{Repo.get_by!(Page, board_id: board.id, title: "Architecture").code})"

      assert md =~ "building or changing a screen"
      refute md =~ "| Index"
      assert md =~ "No decisions written yet."

      {:ok, _} =
        Wiki.create_page(board, %{
          "title" => "Glossary",
          "folder_id" => folder.id,
          "summary" => "Words we use",
          "front_matter" => "---\nread_when: naming things\n---\n\n"
        })

      md = Renderer.to_markdown(index.body, board: board, as: user, page: index)
      assert md =~ "Glossary"
      assert md =~ "naming things"

      html = Renderer.to_html(index.body, board: board, as: user, page: index)
      assert html =~ ~s|href="/boards/#{board.id}/wiki/|
      assert html =~ "Glossary"
    end
  end

  describe "the pages: query" do
    test "names a folder that is missing, and refuses an empty one", %{user: user, board: board} do
      md = Renderer.to_markdown("```slipdock\npages: Nowhere\n```", board: board, as: user)
      assert md =~ "no folder \"Nowhere\""

      assert {:error, message} = Slipdock.Wiki.Query.parse("pages: /")
      assert message =~ "pages names a folder"
    end

    test "an empty folder says so, or says what `empty:` asks", %{user: user, board: board} do
      {:ok, _} = Folders.create(board, %{"name" => "Empty"})

      assert Renderer.to_markdown("```slipdock\npages: Empty\n```", board: board, as: user) =~
               "No pages in this folder yet."

      assert Renderer.to_markdown("```slipdock\npages: Empty\nempty: \"none\"\n```",
               board: board,
               as: user
             ) =~ "none"
    end
  end
end
