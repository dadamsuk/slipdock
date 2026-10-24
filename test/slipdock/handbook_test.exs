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

  describe "the Seed and Reconcile cards (#1263)" do
    test "install makes both, the reconcile weekly and waiting on the seed",
         %{user: user, board: board} do
      {:ok, result} = Handbook.install(user, board)
      assert result.report.added["cards"] == ["Seed the handbook", "Reconcile the handbook"]

      seed = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Seed the handbook")

      rec =
        Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Reconcile the handbook")

      assert seed.description =~ "CLAUDE.md"
      assert seed.description =~ "covers:"
      assert seed.description =~ "Handbook/Decisions"
      # Lessons from seeding this project's own handbook (#1268).
      assert seed.description =~ "keep `covers:` narrow"
      assert seed.description =~ "slipdock page props <page> --file F"
      assert rec.description =~ "git log"
      assert rec.description =~ "## Log"

      ready = Slipdock.Flow.ready_list(Boards.get_board!(board.id).columns)
      assert seed.column_id == ready.id

      series = Slipdock.Recurrence.for_card(rec)
      assert series
      assert Slipdock.Recurrence.Series.summary(series) =~ ~r/Mon/i

      assert Enum.map(Boards.get_card!(rec.id).blocked_by, & &1.id) == [seed.id]
    end

    test "installing again (even after the seed is done) makes no second pair",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      seed = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Seed the handbook")
      {:ok, _} = Boards.update_card(seed, %{"completed" => true})

      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["cards"] == []

      assert Repo.aggregate(
               from(c in Slipdock.Boards.Card,
                 where: c.board_id == ^board.id and like(c.title, "%the handbook")
               ),
               :count
             ) == 2
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

  describe "for_card/3 (#1264)" do
    setup %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      {:ok, t} = Boards.find_template(nil, "Simple")
      [col | _] = board.columns
      epic = card_fixture(col, %{"title" => "Epic"})
      {:ok, sub} = sub_board(epic, t)
      [sub_col | _] = Boards.get_board!(sub.id).columns
      story = card_fixture(sub_col, %{"title" => "Story"})
      {:ok, subsub} = sub_board(story, t)
      [deep_col | _] = Boards.get_board!(subsub.id).columns
      %{deep_col: deep_col, col: col}
    end

    test "a subcard two sub-boards down gets the root's index and the UI sections",
         %{user: user, board: board, deep_col: deep_col} do
      card =
        card_fixture(deep_col, %{
          "title" => "UI: a reusable dropdown menu component for the card form"
        })

      reading = Handbook.for_card(card, user)
      assert reading.board == Boards.get_board!(board.id).code
      assert reading.index_page == Handbook.find(board).index.code
      assert "UX & UI" in Enum.map(reading.index, & &1.title)
      refute "Index" in Enum.map(reading.index, & &1.title)
      assert reading.more == 0

      titles = Enum.map(reading.suggested, & &1.title)
      assert length(reading.suggested) <= 5
      assert Enum.take(Enum.uniq(titles), 2) |> Enum.sort() == ["Components", "UX & UI"]
      assert Enum.find(reading.suggested, &(&1.title == "UX & UI")).section =~ "UX & UI/"
    end

    test "a board without a handbook gives nil", %{user: user} do
      other = board_fixture(%{}, owner: user)
      [col | _] = other.columns
      assert Handbook.for_card(card_fixture(col, %{"title" => "UI menu"}), user) == nil
    end

    test "a page whose covers glob matches a path the card names comes first",
         %{user: user, board: board, col: col} do
      arch = Repo.get_by!(Page, board_id: board.id, title: "Architecture")

      {:ok, _} =
        Wiki.update_page(arch, %{
          "front_matter" =>
            "---\nhandbook: architecture\nread_when: x\ncovers: [lib/app/**, priv/repo/migrations/**]\n---\n\n"
        })

      card =
        card_fixture(col, %{
          "title" => "Fix the menu",
          "description" => "The bug is in `lib/app/accounts/user.ex`."
        })

      [first | _] = Handbook.for_card(card, user).suggested
      assert first.title == "Architecture"
      assert first.section == nil
      assert first.why == "covers lib/app/accounts/user.ex"
    end

    test "the index stays under its cap however many pages the folder holds",
         %{user: user, board: board, col: col} do
      %{folder: folder} = Handbook.find(board)

      for i <- 1..40 do
        {:ok, _} =
          Wiki.create_page(board, %{
            "title" => "Extra #{i}",
            "folder_id" => folder.id,
            "summary" => String.duplicate("long summary ", 20),
            "front_matter" => "---\nread_when: #{String.duplicate("often ", 30)}\n---\n\n"
          })
      end

      reading = Handbook.for_card(card_fixture(col, %{"title" => "Anything"}), user)
      assert byte_size(Jason.encode!(reading.index)) <= Handbook.index_cap()
      assert reading.more > 0
      assert Enum.all?(reading.index, &(String.length(&1.summary || "") <= 80))
    end

    test "the eight sections always fit, however long their fields (#1283)",
         %{user: user, board: board, col: col} do
      for page <- tl(Handbook.find(board).pages) do
        {:ok, _} =
          Wiki.update_page(page, %{
            "summary" => String.duplicate("a long summary ", 10),
            "front_matter" =>
              "---\nhandbook: x\nread_when: #{String.duplicate("when changing things ", 10)}\n---\n\n"
          })
      end

      reading = Handbook.for_card(card_fixture(col, %{"title" => "Anything"}), user)
      assert length(reading.index) == 8
      assert reading.more == 0
    end

    test "a reader who can't read the root board gets nothing", %{board: board, col: col} do
      stranger = user_fixture("handbook-reader@example.com")
      card = card_fixture(col, %{"title" => "UI menu"})
      assert Handbook.for_card(card, stranger) == nil
      assert Handbook.for_board(board, stranger) == nil
    end

    test "for_board lists the index and the decisions", %{user: user, board: board} do
      {:ok, dec} = Folders.find(board, "/Handbook/Decisions")

      {:ok, _} =
        Wiki.create_page(board, %{"title" => "Decision: soft gate", "folder_id" => dec.id})

      reading = Handbook.for_board(board, user)
      assert length(reading.index) == 8
      assert Enum.map(reading.decisions, & &1.title) == ["Decision: soft gate"]
    end
  end

  describe "suggestions read as real sections (#1281)" do
    test "a chunk's part number and the page's lone top heading are not sections" do
      page = %Page{body: "# Operations\n\nIntro.\n\n## Deploy\n\nPush.\n"}
      assert Handbook.section_path("Operations/Deploy#2", page) == "Operations/Deploy"
      assert Handbook.section_path("Operations/Deploy", page) == "Operations/Deploy"
      assert Handbook.section_path("Operations#4", page) == nil
      assert Handbook.section_path("Operations", page) == nil
      assert Handbook.section_path("", page) == nil
      assert Handbook.section_path(nil, page) == nil

      flat = %Page{body: "## Deploy\n\nPush.\n"}
      assert Handbook.section_path("Deploy#1", flat) == "Deploy"
    end

    test "no page takes more than two of the five", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      ux = Repo.get_by!(Page, board_id: board.id, title: "UX & UI")

      body =
        "# UX & UI\n\n" <>
          Enum.map_join(1..6, "\n\n", &"## Dropdown menu #{&1}\n\nDropdown menu rules.")

      {:ok, _} = Wiki.update_page(ux, %{"body" => body})
      [col | _] = board.columns
      card = card_fixture(col, %{"title" => "Dropdown menu component on the card form"})

      suggested = Handbook.for_card(card, user).suggested
      assert Enum.count(suggested, &(&1.title == "UX & UI")) == 2
      assert length(suggested) > 2
    end
  end

  describe "glob_match?/2 and mentioned_paths/1" do
    test "** crosses folders, * doesn't, and a folder matches what is under it" do
      assert Handbook.glob_match?("lib/app/**", "lib/app/a/b.ex")
      assert Handbook.glob_match?("lib/*.ex", "lib/a.ex")
      refute Handbook.glob_match?("lib/*.ex", "lib/a/b.ex")
      assert Handbook.glob_match?("lib/app/**", "lib/app/")
      refute Handbook.glob_match?("lib/app/**", "test/app/x.exs")
      refute Handbook.glob_match?(nil, "lib/a.ex")
    end

    test "finds paths and files, not urls" do
      paths =
        Handbook.mentioned_paths(
          "See lib/app/x.ex and mix.exs, https://example.com/a/b, and assets/css/"
        )

      assert "lib/app/x.ex" in paths
      assert "mix.exs" in paths
      assert "assets/css/" in paths
      refute Enum.any?(paths, &String.contains?(&1, "example.com"))
    end
  end
end
