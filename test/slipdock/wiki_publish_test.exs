defmodule Slipdock.WikiPublishTest do
  @moduledoc """
  Phase 6: publishing a page to the open web, the automation that writes one,
  and getting a whole wiki out and back in as Markdown.

  The publishing tests are mostly about what a published page *does not* do:
  a live query and a followable link both need permissions, and an anonymous
  request has none.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Wiki}
  alias Slipdock.Wiki.{Archive, Page}
  alias SlipdockWeb.Wiki.Renderer

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Published", "code" => "published"}, owner: user)
    %{user: user, board: board, column: hd(board.columns)}
  end

  describe "publishing" do
    test "gives a page a link and answers its queries once", %{
      board: board,
      column: column,
      user: user
    } do
      card_fixture(column, %{"title" => "Open work", "flags" => ["blocked"]})

      body = """
      Blocked right now:

      ```kanban
      view: count
      filter: flag=blocked
      ```

      There are {{count: flag=blocked}} of them.
      """

      {:ok, page} = Wiki.create_page(board, %{"title" => "Status", "body" => body}, user: user)
      {:ok, published} = Wiki.publish(page, user: user)

      assert published.public_token
      assert published.published_at
      assert published.frozen["count: flag=blocked"] == "1"

      assert %{"kind" => "count", "count" => 1} =
               Map.get(published.frozen, "view: count\nfilter: flag=blocked")

      # Another blocked card afterwards does not change what the published
      # page says: the answers were worked out when it was published.
      card_fixture(column, %{"title" => "Another", "flags" => ["blocked"]})
      reread = Wiki.get_published(published.public_token)

      html = Renderer.to_html(reread.body, page: reread, static: true, frozen: reread.frozen)
      assert html =~ ">1</span>"
      refute html =~ ">2</span>"

      {:ok, again} = Wiki.publish(reread, user: user)
      assert again.frozen["count: flag=blocked"] == "2"
    end

    test "a frozen block renders its answer, not nothing", %{
      board: board,
      column: column,
      user: user
    } do
      card_fixture(column, %{"title" => "Open work", "flags" => ["blocked"]})

      body = "```kanban\nview: list\nfilter: flag=blocked\n```\n"
      {:ok, page} = Wiki.create_page(board, %{"title" => "Blocked", "body" => body}, user: user)
      {:ok, published} = Wiki.publish(page, user: user)

      html =
        Renderer.to_html(published.body, page: published, static: true, frozen: published.frozen)

      assert html =~ "wiki-query-list"
      assert html =~ "Open work"
      refute html =~ "wiki-query-error"
    end

    test "a table block survives the round trip through JSON", %{
      board: board,
      column: column,
      user: user
    } do
      card_fixture(column, %{"title" => "Open work", "priority" => "high"})

      body = "```kanban\nview: table\nfields: title, priority\n```\n"
      {:ok, page} = Wiki.create_page(board, %{"title" => "Table", "body" => body}, user: user)
      {:ok, published} = Wiki.publish(page, user: user)

      # The frozen answer comes back with string keys, so re-read it the way a
      # published page actually does.
      reread = Wiki.get_published(published.public_token)
      html = Renderer.to_html(reread.body, page: reread, static: true, frozen: reread.frozen)

      assert html =~ "wiki-query-table"
      assert html =~ "Open work"
      assert html =~ "high"
    end

    test "nothing in a published page is followable", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Commercially sensitive"})
      {:ok, _} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      {:ok, page} =
        Wiki.create_page(
          board,
          %{"title" => "Notes", "body" => "See [[Retry policy]] about ##{card.id}."},
          user: user
        )

      {:ok, published} = Wiki.publish(page, user: user)

      html =
        Renderer.to_html(published.body, page: published, static: true, frozen: published.frozen)

      refute html =~ "<a href=\"/boards/"
      assert html =~ "Retry policy"
      assert html =~ "wiki-static"
    end

    test "a draft cannot be published", %{board: board, user: user} do
      {:ok, draft} =
        Wiki.create_page(board, %{"title" => "Half", "status" => "draft"}, user: user)

      assert {:error, :unprocessable_entity, message} = Wiki.publish(draft, user: user)
      assert message =~ "draft cannot be published"
    end

    test "a withdrawn link stops working, and so does an archived page's", %{
      board: board,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Open"}, user: user)
      {:ok, published} = Wiki.publish(page, user: user)
      token = published.public_token

      assert %Page{} = Wiki.get_published(token)

      {:ok, _} = Wiki.archive_page(published)
      assert Wiki.get_published(token) == nil

      {:ok, restored} = Wiki.unarchive_page(Wiki.get_page!(published.id))
      assert %Page{} = Wiki.get_published(token)

      {:ok, _} = Wiki.unpublish(restored)
      assert Wiki.get_published(token) == nil
    end
  end

  describe "automations" do
    test "has_doc knows whether anything has been written about a card", %{
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})
      conditions = [%{"field" => "has_doc", "op" => "is", "value" => true}]

      refute Automations.Runner.conditions_match?(conditions, Boards.get_card!(card.id))

      {:ok, _} = Wiki.create_page_from_card(card, user: user)
      assert Automations.Runner.conditions_match?(conditions, Boards.get_card!(card.id))
    end

    test "create_page writes a page for the card and pins it", %{
      board: board,
      column: column
    } do
      card = card_fixture(column, %{"title" => "Needs a spec"})

      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_moved", "to" => "In Progress"},
          "conditions" => [],
          "actions" => [%{"type" => "create_page", "title" => "Spec for {{card.title}}"}]
        })

      Automations.run_now(rule, Boards.get_card!(card.id))

      assert [%{pinned: true, page: page}] = Wiki.pages_for_card(card)
      assert page.title == "Spec for Needs a spec"
      assert [revision | _] = Wiki.list_revisions(page)
      assert revision.via == "automation"
    end
  end

  describe "out and back in" do
    setup %{board: board, user: user} do
      {:ok, parent} =
        Wiki.create_page(
          board,
          %{
            "title" => "Deploys",
            "summary" => "How we ship",
            "body" => "# Deploys\n\nThe shape of it."
          },
          user: user
        )

      {:ok, child} =
        Wiki.create_page(
          board,
          %{"title" => "Rollback", "parent_id" => parent.id, "body" => "Stop the queue."},
          user: user
        )

      %{parent: parent, child: child}
    end

    test "the tree becomes folders, and front matter carries the rest", %{board: board} do
      files = Archive.files(board) |> Map.new()

      assert Map.has_key?(files, "Deploys/index.md")
      assert Map.has_key?(files, "Deploys/Rollback.md")

      index = files["Deploys/index.md"]
      assert index =~ "title: Deploys"
      assert index =~ "summary: How we ship"
      assert index =~ ~r/^code: W-\d+$/m
      assert index =~ "# Deploys"
    end

    test "a wiki folder is a directory, and comes back as a folder", %{
      board: board,
      user: user
    } do
      {:ok, folder} = Wiki.create_folder(board, %{"name" => "Design/Decisions"})
      {:ok, page} = Wiki.create_page(board, %{"title" => "Why SQLite"}, user: user)
      {:ok, _} = Wiki.file_page(page, folder)

      files = Archive.files(board) |> Map.new()
      assert Map.has_key?(files, "Design/Decisions/Why SQLite.md")
      # A directory with no index.md is filing, not a page about nothing.
      refute Map.has_key?(files, "Design/Decisions/index.md")

      elsewhere = board_fixture(%{"name" => "Copy 2", "code" => "copy2"}, owner: user)
      result = Archive.import_files(elsewhere, Archive.files(board), user: user)

      assert result.skipped == []
      assert {:ok, there} = Wiki.find_page(elsewhere, "Why SQLite")
      assert {:ok, same} = Wiki.find_folder(elsewhere, "Design/Decisions")
      assert there.folder_id == same.id
      # And the page tree came across beside it, unconfused with the filing.
      assert {:ok, %{parent_id: parent_id}} = Wiki.find_page(elsewhere, "Rollback")
      assert {:ok, %{id: ^parent_id}} = Wiki.find_page(elsewhere, "Deploys")
    end

    test "references are left exactly as written", %{board: board, user: user} do
      {:ok, _} =
        Wiki.create_page(board, %{"title" => "Index", "body" => "See [[Rollback]] and #1."},
          user: user
        )

      files = Archive.files(board) |> Map.new()
      assert files["Index.md"] =~ "See [[Rollback]] and #1."
    end

    test "a zip is a zip", %{board: board} do
      {name, binary} = Archive.zip(board)
      assert name == "published-wiki.zip"
      assert {:ok, entries} = :zip.list_dir(binary)
      names = for {:zip_file, path, _, _, _, _} <- entries, do: to_string(path)
      assert "Deploys/index.md" in names
    end

    test "importing rebuilds the tree on another board", %{board: board, user: user} do
      files = Archive.files(board)
      elsewhere = board_fixture(%{"name" => "Copy", "code" => "copy"}, owner: user)

      result = Archive.import_files(elsewhere, files, user: user, via: "cli")

      assert length(result.created) == 2
      assert result.skipped == []

      assert [%{page: top, children: [%{page: under}]}] = Wiki.tree(elsewhere)
      assert top.title == "Deploys"
      assert top.summary == "How we ship"
      assert under.title == "Rollback"
      assert under.body =~ "Stop the queue."
    end

    test "importing twice is not a wiki twice", %{board: board, user: user} do
      files = Archive.files(board)
      elsewhere = board_fixture(%{"name" => "Copy", "code" => "copy2"}, owner: user)

      Archive.import_files(elsewhere, files, user: user)
      again = Archive.import_files(elsewhere, files, user: user)

      assert again.created == []
      assert length(again.skipped) == 2
      assert hd(again.skipped).reason =~ "already here"
      assert length(Wiki.list_pages(elsewhere)) == 2
    end

    test "--overwrite replaces rather than skipping", %{board: board, user: user} do
      elsewhere = board_fixture(%{"name" => "Copy", "code" => "copy3"}, owner: user)

      {:ok, _} =
        Wiki.create_page(elsewhere, %{"title" => "Rollback", "body" => "old words"}, user: user)

      result =
        Archive.import_files(elsewhere, Archive.files(board), user: user, overwrite: true)

      assert result.skipped == []
      {:ok, page} = Wiki.find_page(elsewhere, "Rollback")
      assert page.body =~ "Stop the queue."
    end

    test "a folder of plain Markdown imports without front matter", %{user: user} do
      dir = Path.join(System.tmp_dir!(), "wiki-import-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "Runbooks"))
      File.write!(Path.join(dir, "Charter.md"), "# Charter\n\nWhy we exist.\n")
      File.write!(Path.join([dir, "Runbooks", "index.md"]), "The runbooks.\n")
      File.write!(Path.join([dir, "Runbooks", "Deploy.md"]), "Push the button.\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      board = board_fixture(%{"name" => "Imported", "code" => "imported"}, owner: user)
      assert {:ok, result} = Archive.import_folder(board, dir, user: user)

      assert length(result.created) == 3
      titles = Wiki.tree(board) |> Enum.map(& &1.page.title) |> Enum.sort()
      assert titles == ["Charter", "Runbooks"]

      {:ok, runbooks} = Wiki.find_page(board, "Runbooks")
      assert [%{title: "Deploy"}] = Wiki.children(runbooks)
    end

    test "a folder that is not there is an error, not a crash", %{board: board} do
      assert {:error, message} = Archive.import_folder(board, "/nowhere/at/all")
      assert message =~ "is not a folder"
    end
  end
end
