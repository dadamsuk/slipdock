defmodule Slipdock.WikiCardsTest do
  @moduledoc """
  The joins between the board and the wiki: docs on a card, writing a card up,
  making a card out of a passage, templates, and the writing people do in
  comments counting as writing.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Favourites, Wiki}
  alias Slipdock.Wiki.Page

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Handbook", "code" => "handbook2"}, owner: user)
    %{user: user, board: board, column: hd(board.columns)}
  end

  describe "docs on a card" do
    test "a page that mentions a card turns up on it, pinned first", %{
      board: board,
      column: column,
      user: user
    } do
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, mention} =
        Wiki.create_page(board, %{"title" => "Notes", "body" => "a passing ##{card.id}"},
          user: user
        )

      {:ok, spec} =
        Wiki.create_page(board, %{"title" => "Ship spec", "body" => "About ##{card.id}."},
          user: user
        )

      {:ok, _} = Wiki.pin(spec, {:card, card})

      assert [first, second] = Wiki.pages_for_card(card)
      assert first.page.id == spec.id
      assert first.pinned
      assert second.page.id == mention.id
      refute second.pinned
    end
  end

  describe "writing a card up" do
    test "starts a page, pins it, and leaves somewhere to log", %{column: column, user: user} do
      card = card_fixture(column, %{"title" => "Fix retries"})

      {:ok, page} = Wiki.create_page_from_card(card, user: user)

      assert page.title == "Fix retries"
      assert page.body =~ "##{card.id}"
      assert page.body =~ "## Log"
      assert [%{pinned: true}] = Wiki.pages_for_card(card)
    end

    test "starts from a template when the board has one", %{
      board: board,
      column: column,
      user: user
    } do
      {:ok, _} =
        Wiki.create_page(
          board,
          %{
            "title" => "Spec template",
            "template" => true,
            "body" => "# {{card.title}}\n\nOn {{today}}, for ##{"{{card.id}}"}.\n"
          },
          user: user
        )

      card = card_fixture(column, %{"title" => "Fix retries"})

      {:ok, page} =
        Wiki.create_page_from_card(card,
          user: user,
          template: "Spec template",
          title: "Retry spec"
        )

      assert page.title == "Retry spec"
      assert page.body =~ "# Fix retries"
      assert page.body =~ Date.to_iso8601(Date.utc_today())
      assert [%{pinned: true}] = Wiki.pages_for_card(card)
    end

    test "a template is a starting point, not content", %{board: board, user: user} do
      {:ok, template} =
        Wiki.create_page(board, %{"title" => "Runbook template", "template" => true}, user: user)

      assert [%Page{id: id}] = Wiki.list_templates(board)
      assert id == template.id
      assert Wiki.list_pages(board, template: false) == []
    end
  end

  describe "making a card from a passage" do
    test "the first line is the title, and both ends carry the link", %{
      board: board,
      column: column,
      user: user
    } do
      {:ok, page} =
        Wiki.create_page(
          board,
          %{
            "title" => "Findings",
            "body" => "Intro.\n\nRetries are wrong\nThey retry forever.\n"
          },
          user: user
        )

      {:ok, card} =
        Wiki.create_card_from_selection(
          page,
          column,
          "Retries are wrong\nThey retry forever.",
          user: user
        )

      assert card.title == "Retries are wrong"
      assert card.description =~ "They retry forever."
      assert card.description =~ "/boards/#{board.id}/wiki/findings"

      # The page says where the work went, and the link graph agrees.
      assert Wiki.get_page!(page.id).body =~ "(##{card.id})"
      assert [%{page: %{id: id}}] = Wiki.pages_for_card(card)
      assert id == page.id
    end

    test "a passage that cannot be found verbatim still records the link", %{
      board: board,
      column: column,
      user: user
    } do
      {:ok, page} =
        Wiki.create_page(board, %{"title" => "Findings", "body" => "Some prose."}, user: user)

      {:ok, card} =
        Wiki.create_card_from_selection(page, column, "text that is not in the body", user: user)

      assert Wiki.get_page!(page.id).body == "Some prose."
      assert [%{page: %{id: id}}] = Wiki.pages_for_card(card)
      assert id == page.id
    end
  end

  describe "board templates" do
    test "a board made from one arrives with its pages", %{user: user} do
      {:ok, template} =
        Boards.create_template(%{
          "name" => "Project #{System.unique_integer([:positive])}",
          "columns" => ["To Do", "Done"],
          "pages" => [
            %{"title" => "Charter", "body" => "# {{board.name}}\n\nStarted {{today}}."},
            %{"title" => "Decision record", "template" => true, "body" => "# Decision\n"}
          ]
        })

      board = board_fixture(%{"name" => "Fresh"}, owner: user, template: template)

      titles = board |> Wiki.list_pages() |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Charter", "Decision record"]

      {:ok, charter} = Wiki.find_page(board, "Charter")
      assert charter.body =~ "# Fresh"
      assert charter.body =~ Date.to_iso8601(Date.utc_today())

      assert [%{title: "Decision record"}] = Wiki.list_templates(board)
    end
  end

  describe "writing on cards counts as writing" do
    test "a comment linking a page shows in that page's backlinks", %{
      board: board,
      column: column,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, _} = Boards.add_comment(card, "blocked on [[Retry policy]], see there")

      assert [link] = Wiki.backlinks(page, user)
      assert link.source_card.id == card.id
      assert is_nil(link.page)
    end

    test "a status update's note does too, and editing takes it away", %{
      board: board,
      column: column,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)
      card = card_fixture(column, %{"title" => "Ship it"})

      {:ok, update} =
        Boards.add_status_update(card, user, %{
          "health" => "at_risk",
          "body" => "see [[Retry policy]]"
        })

      assert [%{source_card: %{id: id}}] = Wiki.backlinks(page, user)
      assert id == card.id

      Boards.delete_status_update(update.id)
      assert Wiki.backlinks(page, user) == []
    end

    test "a backlink from a card the reader cannot open is not shown", %{
      board: board,
      column: column,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)
      card = card_fixture(column, %{"title" => "Ship it"})
      {:ok, _} = Boards.add_comment(card, "see [[Retry policy]]")

      outsider = user_fixture("cards.outsider@example.com")
      assert [_] = Wiki.backlinks(page, user)
      assert [] = Wiki.backlinks(page, outsider)
    end
  end

  describe "favourites" do
    test "a page can be one, and a draft cannot be one for a reader", %{
      board: board,
      user: user
    } do
      {:ok, page} = Wiki.create_page(board, %{"title" => "Retry policy"}, user: user)

      assert {:ok, :added} = Favourites.toggle(user, :page, page.id)
      assert [%{kind: :page, resource: %Page{}}] = Favourites.list(user)
      assert Favourites.favourite?(Favourites.marks(user), :page, page.id)

      assert {:ok, :removed} = Favourites.toggle(user, :page, page.id)
      assert Favourites.list(user) == []
    end
  end
end
